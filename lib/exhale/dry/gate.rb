# frozen_string_literal: true

require "set"
require_relative "../errors"

module Exhale
  module Dry
    # One cluster of duplicated code in the report. copy is the newest
    # location; others are the rest, each with its score against the copy.
    Finding = Struct.new(:klass, :kind, :score, :copy, :others, :hint, :payoff, :primitive, :touched,
                         keyword_init: true)
    Kept = Struct.new(:score, :a, :b, :clause, :new_clause, keyword_init: true)
    # a and b are the two sides' identities; a pair is contracted by its
    # keys, but reported by the names a reader knows.
    Contracted = Struct.new(:a, :b, :score, keyword_init: true)
    Result = Struct.new(:findings, :kept, :contracted, :clause_errors, :parse_errors, :base_sha, :exit_code,
                        :notes, :introduced_only, :touched, keyword_init: true)

    # What a base sweep leaves behind for labeling: which finding each
    # location sat in there, found by its key or by its structure, every
    # pair that matched, and which clauses existed.
    #
    # clusters    - {location key => cluster id}
    # structures  - {structural key => [cluster id, ...]}
    # pairs       - [[key a, key b, score, structural a, structural b, identity a, identity b], ...]
    # clause_keys - Set of clause keys
    BaseSummary = Struct.new(:clusters, :structures, :pairs, :clause_keys, keyword_init: true)

    # Turns a sweep's matches into the verdict. The verdict reads only the
    # tree being checked; the base summary only labels findings, except in
    # the introduced-only on-ramp.
    class Gate
      ORDER = { introduced: 0, shifted: 1, already_there: 2, found: 3 }.freeze
      FAILS_ON_RAMP = %i[introduced shifted found].freeze

      # Every base match, kept or not, joins its two locations into one base
      # cluster, the same union the head's findings come from. A label then
      # asks whether two locations sat in one cluster, so a relationship the
      # matcher only implied (A~B and B~C, or a star around a hub) still
      # counts.
      def self.summarize(sweep)
        sets = UnionFind.new
        sweep.matches.each { |m| sets.union(m.a.key, m.b.key) }
        roots = sets.keys.group_by { |key| sets.find(key) }.values.map(&:sort).sort
        clusters = roots.each_with_index.each_with_object({}) { |(keys, id), map| keys.each { |key| map[key] = id } }
        structures = Hash.new { |hash, key| hash[key] = Set.new }
        sweep.matches.each do |m|
          [m.a, m.b].each { |l| structures[l.structural_key] << clusters.fetch(l.key) }
        end

        BaseSummary.new(
          clusters: clusters,
          structures: structures.transform_values { |ids| ids.to_a.sort },
          pairs: sweep.matches.map { |m| pair_row(m) }.sort_by { |row| row.values_at(0, 1, 3, 4) },
          clause_keys: Set.new(sweep.contract.clauses.map(&:key))
        )
      end

      def self.pair_row(match)
        a, b = [match.a, match.b].sort_by(&:key)
        [a.key, b.key, match.score, *[a.structural_key, b.structural_key].sort, a.unit.identity, b.unit.identity]
      end

      # Disjoint sets over any hashable keys.
      class UnionFind
        def initialize
          @parent = {}
        end

        def keys
          @parent.keys
        end

        def find(key)
          @parent[key] = key unless @parent.key?(key)
          root = key
          root = @parent[root] until @parent[root] == root
          while @parent[key] != root
            @parent[key], key = root, @parent[key]
          end
          root
        end

        def union(a, b)
          root_a = find(a)
          root_b = find(b)
          @parent[root_b] = root_a unless root_a == root_b
        end
      end

      def initialize(head:, base:, base_sha:, git:, changed_lines:, introduced_only:, paths:, overrides:)
        @head = head
        @base = base
        @base_sha = base_sha
        @git = git
        @changed_lines = changed_lines
        @introduced_only = introduced_only
        @paths = paths
        @overrides = overrides
        @blame = {}
      end

      def verdict
        kept, unkept, used = partition
        clusters = cluster(unkept)
        prefetch_blame(clusters)
        findings = clusters.map { |locations, matches| finding(locations, matches) }
        findings = narrow(findings) unless @paths.empty?
        findings.sort_by! do |f|
          [ORDER.fetch(f.klass), -f.payoff, f.copy.path, f.copy.start_line, f.copy.end_line, f.copy.unit.identity]
        end
        errors = clause_errors(used)

        Result.new(findings: findings, kept: kept, contracted: contracted, clause_errors: errors,
                   parse_errors: @head.parse_errors, base_sha: @base_sha, notes: notes,
                   introduced_only: @introduced_only, touched: @changed_lines.size,
                   exit_code: exit_code(findings, errors))
      end

      private

      def partition
        used = Set.new
        kept = []
        unkept = []
        @head.matches.each do |match|
          clause = @head.resolver.keeping_clause(match.a.unit, match.b.unit)
          if clause
            used << clause.key
            kept << Kept.new(score: match.score, a: match.a, b: match.b, clause: clause,
                             new_clause: @base ? !@base.clause_keys.include?(clause.key) : false)
          else
            unkept << match
          end
        end
        [kept, unkept + unkept_twins(kept), used]
      end

      # The matcher joins a group of identical units as a star around one
      # hub, so a kept edge from the hub says nothing about the members the
      # star never paired. Each kept edge between whole units stands for
      # every pair across the two groups it touches (or within the one group),
      # and each of those pairs the Contract doesn't keep is unkept
      # duplication. A group no clause touches needs no expansion: its star
      # edges are unkept already.
      def unkept_twins(kept)
        groups = @head.matches.flat_map { |m| [m.a, m.b] }.select(&:whole).uniq(&:id)
                      .group_by { |l| l.entry.tree.digest }
        emitted = Set.new(@head.matches.map { |m| [m.a.id, m.b.id].sort })
        expanded = Set.new
        kept.each_with_object([]) do |k, extra|
          next unless k.a.whole && k.b.whole

          pair = [k.a.entry.tree.digest, k.b.entry.tree.digest].sort
          next unless expanded.add?(pair)

          left = groups.fetch(pair[0])
          right = groups.fetch(pair[1])
          next if left.size == 1 && right.size == 1

          candidates = pair[0] == pair[1] ? left.combination(2) : left.product(right)
          candidates.each do |a, b|
            next if emitted.include?([a.id, b.id].sort)
            next if @head.resolver.keeping_clause(a.unit, b.unit)

            match = twin_match(a, b, pair[0] == pair[1] ? Rational(1) : k.score)
            extra << match if match
          end
        end
      end

      # Identical units share their fingerprints, so a pair across two groups
      # scores what their hubs scored. Each pair still meets its own settings.
      def twin_match(a, b, score)
        settings = @head.settings_for_pair(a.unit, b.unit)
        return unless [a, b].all? { |l| l.lines >= settings[:min_lines] && l.size >= settings[:min_nodes] }
        return if score < settings[:threshold]

        Match.new(a: a, b: b, score: score, kind: :unit)
      end

      # Matches that share a location merge, so one shape copied into four
      # controllers is one finding with four locations.
      def cluster(matches)
        parent = {}
        find = lambda do |id|
          parent[id] = id unless parent.key?(id)
          root = id
          root = parent[root] until parent[root] == root
          parent[id] = root
        end

        location_of = {}
        matches.each do |match|
          a = location_id(match.a)
          b = location_id(match.b)
          location_of[a] = match.a
          location_of[b] = match.b
          root_a = find.call(a)
          root_b = find.call(b)
          parent[root_b] = root_a unless root_a == root_b
        end

        groups = Hash.new { |hash, root| hash[root] = [[], []] }
        location_of.each_key { |id| groups[find.call(id)][0] << location_of[id] }
        matches.each { |match| groups[find.call(location_id(match.a))][1] << match }
        groups.values
      end

      def location_id(location)
        [location.entry.id, location.start_line, location.end_line]
      end

      def finding(locations, matches)
        @scores = matches.to_h { |m| [[location_id(m.a), location_id(m.b)].sort, m.score] }
        ordered = locations.sort_by { |l| [age(l), l.path, l.start_line, l.end_line] }
        original = ordered.first
        copy = ordered.last
        others = (locations - [copy]).map { |l| [l, score_between(copy, l)] }
        others.sort_by! { |l, score| [-score, l.path, l.start_line, l.end_line] }
        touched = locations.select { |l| touched?(l) }
        primitive = @head.resolver.primitive_for(original.unit)&.name

        Finding.new(klass: label(copy, original, locations, touched), kind: kind_of(locations),
                    score: others.first[1], copy: copy, others: others, primitive: primitive, touched: touched,
                    hint: hint(copy, others, locations, touched, primitive),
                    payoff: payoff(locations, original, copy))
      end

      BLAME_THREADS = 8

      # One blame per file, run a few at a time. Each result depends only on
      # its own file, so the order the threads finish in changes nothing.
      def prefetch_blame(clusters)
        return unless @git

        paths = clusters.flat_map { |locations, _| locations.reject { |l| touched?(l) }.map(&:path) }.uniq
        queue = Queue.new
        paths.each { |path| queue << path }
        queue.close
        results = {}
        lock = Mutex.new
        Array.new([BLAME_THREADS, paths.size].min) do
          Thread.new do
            while (path = queue.pop)
              times = begin
                @git.blame_times(path)
              rescue GitError
                []
              end
              lock.synchronize { results[path] = times }
            end
          end
        end.each(&:join)
        @blame.merge!(results)
      end

      # Older lines are the original. A touched location is the newest thing
      # there is; with no git, path order decides.
      def age(location)
        return Float::INFINITY if touched?(location)
        return 0 unless @git

        times = (@blame[location.path] ||= @git.blame_times(location.path))
        times[(location.start_line - 1)..(location.end_line - 1)].compact.max || 0
      rescue GitError
        0
      end

      def touched?(location)
        lines = @changed_lines[location.path]
        lines && (location.start_line..location.end_line).any? { |line| lines.include?(line) }
      end

      # A hash lookup per pair, so a finding with hundreds of copies stays
      # cheap; only pairs the matcher never scored directly get computed.
      def score_between(a, b)
        @scores.fetch([location_id(a), location_id(b)].sort) do
          @head.index.score(a.set, total(a), b.set, total(b))
        end
      end

      def total(location)
        location.whole ? location.entry.total : @head.index.weight_of(location.set)
      end

      # Each touched location answers for itself: one that sat in no base
      # finding with any other location in this finding is new, whatever
      # else in the finding was there before. That way a PR can't hide a new
      # copy behind an old pair by also editing an old copy.
      #
      # Pure moves touch no lines, so structure only vouches for a finding
      # the PR left alone entirely: it's already there when every location
      # sat in one base finding, each found by its key or by its structure.
      def label(_copy, _original, locations, touched)
        return :found unless @base

        unless touched.empty?
          introduced = touched.any? { |l| locations.none? { |other| !other.equal?(l) && base_pair?(l, other) } }
          return introduced ? :introduced : :already_there
        end
        shared = locations.map { |l| base_clusters(l) }.reduce(:&)
        shared.empty? ? :shifted : :already_there
      end

      def base_pair?(a, b)
        cluster = @base.clusters[a.key]
        !cluster.nil? && cluster == @base.clusters[b.key]
      end

      def base_clusters(location)
        ids = Set.new(@base.structures.fetch(location.structural_key, []))
        cluster = @base.clusters[location.key]
        ids << cluster if cluster
        ids
      end

      def kind_of(locations)
        return locations.first.unit.kind if locations.all?(&:whole) && locations.map { |l| l.unit.kind }.uniq.size == 1

        :fragment
      end

      def hint(copy, others, locations, touched, primitive)
        text = base_hint(copy, others, locations)
        text = "promote one copy to a shared primitive before merge" if touched.size == locations.size && @base
        primitive ? "#{text}; it belongs to the #{primitive} primitive" : text
      end

      def base_hint(copy, others, locations)
        existing = others.first[0]
        if copy.unit.language == :erb
          return "render the existing partial #{existing.unit.identity}" if existing.whole && partial?(existing)

          return "extract a partial or a component"
        end
        return "extend or call #{existing.unit.identity}" if locations.all?(&:whole)

        namespaces = locations.map { |l| l.unit.namespace }.uniq
        return "extract a method" if namespaces.size == 1

        where = "#{locations.size} copies in #{namespaces.size} classes"
        if locations.all? { |l| l.path.start_with?("app/models/", "app/controllers/") }
          "#{where}; extract a concern"
        else
          "#{where}; extract a concern, or a service object"
        end
      end

      def partial?(location)
        File.basename(location.path).start_with?("_")
      end

      # The code that would disappear if the cluster folded into one copy.
      def payoff(locations, original, copy)
        (locations - [original]).sum do |l|
          score = l.equal?(copy) ? score_between(copy, original) : score_between(copy, l)
          l.size * score
        end.to_f.round(1)
      end

      # Paths arrive relative to the root and already checked to exist; "."
      # is the whole tree.
      def narrow(findings)
        findings.select do |f|
          [f.copy, *f.others.map(&:first)].any? do |l|
            @paths.any? { |p| p == "." || l.path == p || l.path.start_with?("#{p}/") }
          end
        end
      end

      def clause_errors(used)
        stale = @head.contract.clauses.reject { |clause| used.include?(clause.key) }.map do |clause|
          ContractError.new(clause.path, clause.line,
                            "stale clause: nothing it covers duplicates anything over the threshold; delete it")
        end
        @head.contract.errors + @head.resolver.errors + stale
      end

      # Counted per occurrence: each structural pair the base matched more
      # often than the head does lost that many pairs, so deleting one of
      # three identical copies contracts one pair even though a pair of the
      # same shape survives. A pair still matched under its own keys never
      # counts as lost, and a pure move keeps its structure, so it doesn't
      # either.
      def contracted
        return [] unless @base

        keys = Set.new
        structural = Hash.new(0)
        @head.matches.each do |m|
          keys << [m.a.key, m.b.key].sort
          structural[[m.a.structural_key, m.b.structural_key].sort] += 1
        end
        @base.pairs.group_by { |row| row.values_at(3, 4) }.flat_map do |shape, rows|
          lost = rows.size - structural[shape]
          next [] unless lost.positive?

          rows.reject { |row| keys.include?(row.values_at(0, 1)) }.first(lost).map do |row|
            Contracted.new(a: row[5], b: row[6], score: row[2])
          end
        end
      end

      def notes
        notes = []
        notes << "no merge base found, so findings are unlabeled" unless @base
        notes << "flags override the Contract, so this run doesn't gate" unless @overrides.empty?
        notes << "narrowed to #{@paths.join(', ')}: only findings there are reported and gated" unless @paths.empty?
        notes << "introduced-only on-ramp: already-there findings are warnings" if @introduced_only
        notes
      end

      # A narrowed run still gates, on the findings it kept, so a path given
      # by mistake can't switch the gate off.
      def exit_code(findings, errors)
        return 2 unless @head.parse_errors.empty?
        return 0 unless @overrides.empty?

        failing = @introduced_only ? findings.select { |f| FAILS_ON_RAMP.include?(f.klass) } : findings
        failing.empty? && errors.empty? ? 0 : 1
      end
    end
  end
end
