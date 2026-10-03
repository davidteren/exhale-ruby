# frozen_string_literal: true

require "set"
require_relative "fingerprints"
require_relative "index"

module Exhale
  module Dry
    # Where one side of a match sits: a whole unit, or a fragment inside one.
    # signature identifies a fragment's structure, so a fragment can be
    # recognized at the base even after its lines move.
    Location = Struct.new(:entry, :start_line, :end_line, :size, :set, :whole, :signature, :ordinal,
                          keyword_init: true) do
      def unit
        entry.unit
      end

      def path
        unit.path
      end

      def lines
        end_line - start_line + 1
      end

      # The file is part of the key: one identity defined in two files is
      # two places, and a base pair keyed by one can't stand for the other.
      def key
        place = "#{path}##{unit.identity}"
        whole ? place : "#{place}@#{signature.to_s(16)}##{ordinal}"
      end

      def structural_key
        signature.to_s(16)
      end

      def contains?(other)
        entry.equal?(other.entry) && start_line <= other.start_line && end_line >= other.end_line
      end

      # Sharing a line of the same file, whether or not the two sit in the
      # same unit: `end; def second` puts two units on one line.
      def overlaps?(other)
        path == other.path && start_line <= other.end_line && other.start_line <= end_line
      end

      # Two locations are the same place when they cover the same lines of
      # the same unit, whichever seeder found them.
      def id
        [entry.id, start_line, end_line]
      end

      def ==(other)
        other.is_a?(Location) && id == other.id
      end
      alias_method :eql?, :==

      def hash
        id.hash
      end
    end

    # A scored pair of locations. kind is :unit, :subtree or :run.
    Match = Struct.new(:a, :b, :score, :kind, keyword_init: true) do
      def size
        [a.size, b.size].max
      end
    end

    # Finds every pair of locations over the threshold. Two seeders propose
    # candidates and one scorer judges them all:
    #
    # 1. Prefix filtering over rarest-first fingerprints finds every
    #    whole-unit pair over the threshold.
    # 2. Exact subtree digests find fragments copied whole, as flay does.
    # 3. Statement-run seeds find runs lifted out of the middle of a sequence,
    #    allowing one mismatched statement.
    #
    # Settings come per pair from the Contract, so the matcher generates
    # candidates at the loosest floors any primitive asks for and judges each
    # pair by its own.
    class Matcher
      RUN = 3
      RUN_SEED_CAP = 50
      STAR_ABOVE = 100

      # Entry id => the id standing for its group of identical units, for
      # every unit the matcher joined to at least one identical copy.
      attr_reader :twins

      def initialize(index, floors:, settings_for_pair:)
        @index = index
        @floors = floors
        @settings_for_pair = settings_for_pair
        @twins = {}
      end

      def matches
        @twins = {}
        eligible = @index.entries.select { |entry| eligible?(entry) }
        found = unit_matches(eligible) + subtree_matches(eligible) + run_matches(eligible)
        prune(found)
      end

      private

      def eligible?(entry)
        entry.unit.lines >= @floors[:min_lines] && entry.tree.size >= @floors[:min_nodes]
      end

      def whole(entry)
        Location.new(entry: entry, start_line: entry.unit.start_line, end_line: entry.unit.end_line,
                     size: entry.tree.size, set: entry.set, whole: true, signature: entry.tree.digest)
      end

      # Units with identical trees are matched within their group, and only
      # representatives enter the search for near copies. Eight hundred
      # identical scaffold actions would otherwise make 320,000 pairs that
      # all say the same thing.
      #
      # Identical units differ only in their lines and in the settings their
      # primitives give them, so one representative stands for every member
      # with the same tree, own settings and line count: those members are
      # interchangeable. A near copy is compared with each representative.
      def unit_matches(eligible)
        identical = eligible.group_by { |entry| entry.tree.digest }.values.flat_map do |members|
          class_star(members.map { |member| whole(member) }).filter_map do |a, b|
            judge(a, b, :unit).tap { |match| join_twins(members.first, a, b) if match }
          end
        end
        buckets = eligible.group_by { |entry| [entry.tree.digest, own_settings(whole(entry)), entry.unit.lines] }.values
        stand_ins = buckets.to_h { |members| [members.first.id, members] }
        identical + prefix_matches(buckets.map(&:first)).flat_map { |match| with_stand_ins(match, stand_ins) }
      end

      def join_twins(first, a, b)
        @twins[a.entry.id] = first.id
        @twins[b.entry.id] = first.id
      end

      # A representative joined to its identical copies carries them all into
      # its finding. One that isn't joined, because its copies all miss their
      # own floors, stands alone, so each copy pairs with the near copy itself.
      def with_stand_ins(match, stand_ins)
        a, b = match.a, match.b
        extra = []
        extra.concat(stand_ins.fetch(a.entry.id).drop(1).map { |entry| [whole(entry), b] }) unless @twins.key?(a.entry.id)
        extra.concat(stand_ins.fetch(b.entry.id).drop(1).map { |entry| [a, whole(entry)] }) unless @twins.key?(b.entry.id)
        [match] + extra.filter_map { |x, y| judge(x, y, :unit) }
      end

      # Connects every qualifying pair among identical locations without
      # listing them all. Floors are two-dimensional and come per primitive,
      # so no single center fits every pair. Copies are split by the settings
      # their primitive gives them; for each pair of settings classes X and Y,
      # the pair floor is the lower of the two in each dimension, every copy
      # meeting it passes with every other (identical, so the score is 1), and
      # a star across X and Y connects them. Cost is classes squared times
      # copies.
      def class_star(locations)
        classes = locations.group_by { |location| own_settings(location) }.values
        pairs = Set.new
        classes.each_with_index do |x, at|
          classes[at..].each do |y|
            floor = @settings_for_pair.call(x.first.unit, y.first.unit)
            xs = x.select { |location| big_enough?(location, floor) }
            ys = x.equal?(y) ? xs : y.select { |location| big_enough?(location, floor) }
            spokes(ys, xs).each { |pair| pairs << pair }
            spokes(xs, ys).each { |pair| pairs << pair } unless x.equal?(y)
          end
        end
        pairs.to_a.sort_by { |a, b| [a.entry.id, a.start_line, b.entry.id, b.start_line] }
      end

      # Each member paired with the first hub that isn't itself and shares no
      # line with it, lower entry id first.
      def spokes(hubs, members)
        members.filter_map do |member|
          hub = hubs.find { |candidate| !candidate.equal?(member) && !candidate.overlaps?(member) }
          next unless hub

          [hub, member].sort_by { |location| [location.entry.id, location.start_line] }
        end
      end

      def own_settings(location)
        @settings_for_pair.call(location.unit, location.unit)
      end

      def prefix_matches(entries)
        postings = Hash.new { |hash, digest| hash[digest] = [] }
        entries.each { |entry| entry.set.each { |digest| postings[digest] << entry } }

        threshold = @floors[:threshold]
        pairs = Set.new
        entries.each do |entry|
          prefix(entry, threshold).each do |digest|
            postings.fetch(digest, []).each do |other|
              next if other.equal?(entry)

              pairs << (entry.id < other.id ? [entry, other] : [other, entry])
            end
          end
        end

        pairs.sort_by { |a, b| [a.id, b.id] }.filter_map do |a, b|
          next if a.tree.digest == b.tree.digest
          next unless comparable_totals?(a, b, threshold)

          judge(whole(a), whole(b), :unit)
        end
      end

      # A pair scoring at least t shares at least t of A's weight, so it must
      # share one of the rarest fingerprints that together carry more than
      # (1 - t) of that weight. Looking up only those finds every such pair,
      # so candidate generation is exact, not a sample.
      def prefix(entry, threshold)
        budget = (1 - threshold) * entry.total
        taken = 0
        entry.set.sort_by { |digest| [@index.count(digest), digest] }.take_while do |digest|
          next false if taken > budget

          taken += @index.weights[digest]
          true
        end
      end

      # Jaccard can't exceed the smaller total over the larger one.
      def comparable_totals?(a, b, threshold)
        small, large = [a.total, b.total].minmax
        small >= threshold * large
      end

      def subtree_matches(eligible)
        groups = Hash.new { |hash, digest| hash[digest] = [] }
        eligible.each do |entry|
          entry.tree.each_node do |node|
            next if node.equal?(entry.tree)
            next if node.lines < @floors[:min_lines] || node.size < @floors[:min_nodes]

            groups[node.digest] << [entry, node]
          end
        end

        groups.each_value.flat_map do |occurrences|
          next [] if occurrences.size < 2

          locations = occurrences.map { |entry, node| fragment(entry, node) }
          pairs = locations.size > STAR_ABOVE ? class_star(locations) : locations.combination(2)
          pairs.filter_map { |a, b| judge(a, b, :subtree) }
        end
      end

      def fragment(entry, node)
        Location.new(entry: entry, start_line: node.start_line, end_line: node.end_line, size: node.size,
                     set: node.digests, whole: false, signature: node.digest,
                     ordinal: subtree_ordinal(entry, node))
      end

      # Which occurrence of this shape inside its unit, counted in preorder.
      # Two copies of one fragment in the same method need different keys, or
      # a new second copy would read as the old first one.
      def subtree_ordinal(entry, node)
        @subtrees ||= {}
        by_digest = (@subtrees[entry.id] ||= entry.tree.each_node.group_by(&:digest))
        by_digest.fetch(node.digest).index { |candidate| candidate.equal?(node) } + 1
      end

      # Every pair in a small group of run seeds; a star in a big one, which
      # is enough to cluster them without a quadratic blowup. The hub has to
      # be a copy that can pass: see #run_hub.
      def connect(items, cap)
        return items.combination(2).to_a if items.size <= cap

        hub = yield(items)
        items.reject { |item| item.equal?(hub) }.map { |other| [hub, other] }
      end

      # Run seeds aren't locations yet, so the hub is the seed whose window
      # spans the most source lines. A copy squeezed onto one line would fail
      # the line floor against every partner and take the group down with it.
      def run_hub(seeds, sequences)
        seeds.max_by do |id, i|
          children = sequences[id][1].children
          [children[i + RUN - 1].end_line - children[i].start_line, -id, -i]
        end
      end

      def run_matches(eligible)
        sequences = []
        windows = Hash.new { |hash, key| hash[key] = [] }
        eligible.each do |entry|
          entry.tree.each_node do |node|
            next unless node.sequence? && node.children.size >= RUN

            id = sequences.size
            sequences << [entry, node]
            digests = node.children.map(&:digest)
            (0..(digests.size - RUN)).each { |i| windows[digests[i, RUN]] << [id, i] }
          end
        end

        seen = Set.new
        windows.each_value.flat_map do |seeds|
          next [] if seeds.size < 2

          # A run copied past the cap still gets found, as a star from its
          # widest occurrence, the same way big subtree groups are connected.
          connect(seeds, RUN_SEED_CAP) { |group| run_hub(group, sequences) }.filter_map do |(id_a, i), (id_b, j)|
            left = sequences[id_a][1].children
            right = sequences[id_b][1].children
            run = extend_run(left, right, i, j)
            next if id_a == id_b && ranges_overlap?(run[0], run[1], run[2])
            next unless seen.add?([id_a, run[0], id_b, run[1], run[2]])

            judge_run(sequences, id_a, id_b, run) || judge_core(sequences, id_a, id_b, exact_core(left, right, i, j), run, seen)
          end
        end
      end

      def judge_run(sequences, id_a, id_b, run)
        a = run_location(sequences[id_a][0], sequences[id_a][1].children, run[0], run[2])
        b = run_location(sequences[id_b][0], sequences[id_b][1].children, run[1], run[2])
        judge(a, b, :run)
      end

      # A run that spent its mismatch can score under the threshold when the
      # mismatched statements are big. The exact core around the seed is then
      # judged on its own.
      def judge_core(sequences, id_a, id_b, core, run, seen)
        return if core == run || (id_a == id_b && ranges_overlap?(core[0], core[1], core[2]))
        return unless seen.add?([id_a, core[0], id_b, core[1], core[2]])

        judge_run(sequences, id_a, id_b, core)
      end

      # The longest run of identical statements around a seed.
      def exact_core(left, right, i, j)
        length = RUN
        length += 1 while i + length < left.size && j + length < right.size &&
                          left[i + length].digest == right[j + length].digest
        back = 0
        back += 1 while i - back - 1 >= 0 && j - back - 1 >= 0 && left[i - back - 1].digest == right[j - back - 1].digest
        [i - back, j - back, length + back]
      end

      def ranges_overlap?(start_a, start_b, length)
        start_a < start_b + length && start_b < start_a + length
      end

      # Grows a seed in both directions while statements keep matching,
      # spending at most one mismatched statement, as in flay's fuzzy mode.
      def extend_run(left, right, i, j)
        budget = 1
        length = RUN
        while i + length < left.size && j + length < right.size
          if left[i + length].digest == right[j + length].digest
            length += 1
          elsif budget.positive? && i + length + 1 < left.size && j + length + 1 < right.size &&
                left[i + length + 1].digest == right[j + length + 1].digest
            budget -= 1
            length += 2
          else
            break
          end
        end

        back = 0
        while i - back - 1 >= 0 && j - back - 1 >= 0
          if left[i - back - 1].digest == right[j - back - 1].digest
            back += 1
          elsif budget.positive? && i - back - 2 >= 0 && j - back - 2 >= 0 &&
                left[i - back - 2].digest == right[j - back - 2].digest
            budget -= 1
            back += 2
          else
            break
          end
        end

        [i - back, j - back, length + back]
      end

      def run_location(entry, children, start, length)
        nodes = children[start, length]
        set = Set.new
        nodes.each { |node| set.merge(node.digests) }
        signature = Fingerprints.run_digest(nodes)
        Location.new(entry: entry, start_line: nodes.first.start_line, end_line: nodes.last.end_line,
                     size: nodes.sum(&:size), set: set, whole: false, signature: signature,
                     ordinal: run_ordinal(entry, children, start, nodes.map(&:digest)))
      end

      # Which occurrence of this run of statements inside its unit, counting
      # every sequence in preorder, so the key doesn't depend on which other
      # copies happened to match.
      def run_ordinal(entry, children, start, digests)
        count = 0
        entry.tree.each_node do |node|
          next unless node.sequence?

          node_digests = node.children.map(&:digest)
          (0..(node_digests.size - digests.size)).each do |i|
            return count + 1 if node.children.equal?(children) && i == start

            count += 1 if node_digests[i, digests.size] == digests
          end
        end
        count + 1
      end

      def judge(a, b, kind)
        return if a.overlaps?(b)

        settings = @settings_for_pair.call(a.unit, b.unit)
        return unless big_enough?(a, settings) && big_enough?(b, settings)

        score = kind == :subtree ? Rational(1) : @index.score(a.set, total(a), b.set, total(b))
        return if score < settings[:threshold]

        Match.new(a: a, b: b, score: score, kind: kind)
      end

      def big_enough?(location, settings)
        location.lines >= settings[:min_lines] && location.size >= settings[:min_nodes]
      end

      def total(location)
        location.whole ? location.entry.total : @index.weight_of(location.set)
      end

      # Drops any match whose two sides sit inside the two sides of a larger
      # match already kept. A whole-unit match swallows the fragments inside
      # it, and a fragment swallows the smaller fragments inside it.
      def prune(found)
        ordered = found.sort_by do |match|
          [match.a.whole && match.b.whole ? 0 : 1, -match.size, match.a.key, match.b.key, match.a.id, match.b.id]
        end

        kept_by_entries = Hash.new { |hash, key| hash[key] = [] }
        ordered.each_with_object([]) do |match, kept|
          key = [match.a.entry.id, match.b.entry.id].sort
          next if twins?(match)
          next if kept_by_entries[key].any? { |bigger| inside?(match, bigger) }

          kept_by_entries[key] << match
          kept << match
        end
      end

      # Two identical units are already one finding through the star, so a
      # fragment shared between them says nothing new. A fragment repeated
      # inside a single unit still counts.
      def twins?(match)
        return false if match.a.whole || match.a.entry.equal?(match.b.entry)

        twin_a = @twins && @twins[match.a.entry.id]
        twin_a && twin_a == @twins[match.b.entry.id]
      end

      def inside?(match, bigger)
        (bigger.a.contains?(match.a) && bigger.b.contains?(match.b)) ||
          (bigger.a.contains?(match.b) && bigger.b.contains?(match.a))
      end
    end
  end
end
