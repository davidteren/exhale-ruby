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
    Contracted = Struct.new(:a, :b, :score, keyword_init: true)
    Result = Struct.new(:findings, :kept, :contracted, :clause_errors, :parse_errors, :base_sha, :exit_code,
                        :notes, :introduced_only, :touched, keyword_init: true)

    # What a base sweep leaves behind for labeling: which pairs matched there,
    # by identity and by structure, and which clauses existed.
    BaseSummary = Struct.new(:pair_keys, :structural_keys, :pairs, :clause_keys, keyword_init: true)

    # Turns a sweep's matches into the verdict. The verdict reads only the
    # tree being checked; the base summary only labels findings, except in
    # the introduced-only on-ramp.
    class Gate
      ORDER = { introduced: 0, shifted: 1, already_there: 2, found: 3 }.freeze
      FAILS_ON_RAMP = %i[introduced shifted found].freeze

      def self.summarize(sweep)
        BaseSummary.new(
          pair_keys: Set.new(sweep.matches.map { |m| [m.a.key, m.b.key].sort }),
          structural_keys: Set.new(sweep.matches.map { |m| [m.a.structural_key, m.b.structural_key].sort }),
          pairs: sweep.matches.map { |m| [*[m.a.key, m.b.key].sort, m.score, *[m.a.structural_key, m.b.structural_key].sort] }.sort,
          clause_keys: Set.new(sweep.contract.clauses.map(&:key))
        )
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
        findings.sort_by! { |f| [ORDER.fetch(f.klass), -f.payoff, f.copy.path, f.copy.start_line] }
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
        [kept, unkept, used]
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
        ordered = locations.sort_by { |l| [age(l), l.path, l.start_line] }
        original = ordered.first
        copy = ordered.last
        others = (locations - [copy]).map { |l| [l, score_between(copy, l, matches)] }
        others.sort_by! { |l, score| [-score, l.path, l.start_line] }
        touched = locations.select { |l| touched?(l) }
        primitive = @head.resolver.primitive_for(original.unit)&.name

        Finding.new(klass: label(copy, original, touched), kind: kind_of(locations), score: others.first[1],
                    copy: copy, others: others, primitive: primitive, touched: touched,
                    hint: hint(copy, others, locations, touched, primitive),
                    payoff: payoff(locations, original, copy, matches))
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

      def score_between(a, b, matches)
        direct = matches.find { |m| (m.a.equal?(a) && m.b.equal?(b)) || (m.a.equal?(b) && m.b.equal?(a)) }
        return direct.score if direct

        @head.index.score(a.set, total(a), b.set, total(b))
      end

      def total(location)
        location.whole ? location.entry.total : @head.index.weight_of(location.set)
      end

      # Pure moves don't touch any lines, so a pair whose structure already
      # matched at the base counts as already there only when the PR left
      # both sides alone. Otherwise a new copy of an already-copied shape
      # would hide behind the old one.
      def label(copy, original, touched)
        return :found unless @base

        return :already_there if @base.pair_keys.include?([copy.key, original.key].sort)
        if touched.empty? && @base.structural_keys.include?([copy.structural_key, original.structural_key].sort)
          return :already_there
        end

        touched.empty? ? :shifted : :introduced
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
      def payoff(locations, original, copy, matches)
        (locations - [original]).sum do |l|
          score = l.equal?(copy) ? score_between(copy, original, matches) : score_between(copy, l, matches)
          l.size * score
        end.to_f.round(1)
      end

      def narrow(findings)
        findings.select do |f|
          [f.copy, *f.others.map(&:first)].any? { |l| @paths.any? { |p| l.path.include?(p) } }
        end
      end

      def clause_errors(used)
        stale = @head.contract.clauses.reject { |clause| used.include?(clause.key) }.map do |clause|
          ContractError.new(clause.path, clause.line,
                            "stale clause: nothing it covers duplicates anything over the threshold; delete it")
        end
        @head.contract.errors + @head.resolver.errors + stale
      end

      def contracted
        return [] unless @base

        keys = Set.new
        structural = Set.new
        @head.matches.each do |m|
          keys << [m.a.key, m.b.key].sort
          structural << [m.a.structural_key, m.b.structural_key].sort
        end
        @base.pairs.filter_map do |key_a, key_b, score, structural_a, structural_b|
          next if keys.include?([key_a, key_b]) || structural.include?([structural_a, structural_b])

          Contracted.new(a: key_a, b: key_b, score: score)
        end
      end

      def notes
        notes = []
        notes << "no merge base found, so findings are unlabeled" unless @base
        notes << "flags override the Contract, so this run doesn't gate" unless @overrides.empty?
        notes << "narrowed to #{@paths.join(', ')}, so this run doesn't gate" unless @paths.empty?
        notes << "introduced-only on-ramp: already-there findings are warnings" if @introduced_only
        notes
      end

      def exit_code(findings, errors)
        return 2 unless @head.parse_errors.empty?
        return 0 unless @overrides.empty? && @paths.empty?

        failing = @introduced_only ? findings.select { |f| FAILS_ON_RAMP.include?(f.klass) } : findings
        failing.empty? && errors.empty? ? 0 : 1
      end
    end
  end
end
