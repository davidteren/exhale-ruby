# frozen_string_literal: true

require "set"
require_relative "fingerprints"
require_relative "index"

module Exhale
  module Dry
    # Where one side of a match sits: a whole unit, or a fragment inside one.
    # signature identifies a fragment's structure, so a fragment can be
    # recognized at the base even after its lines move.
    Location = Struct.new(:entry, :start_line, :end_line, :size, :set, :whole, :signature, keyword_init: true) do
      def unit
        entry.unit
      end

      def path
        unit.path
      end

      def lines
        end_line - start_line + 1
      end

      def key
        whole ? unit.identity : "#{unit.identity}@#{signature.to_s(16)}"
      end

      def structural_key
        signature.to_s(16)
      end

      def contains?(other)
        entry.equal?(other.entry) && start_line <= other.start_line && end_line >= other.end_line
      end

      def overlaps?(other)
        entry.equal?(other.entry) && start_line <= other.end_line && other.start_line <= end_line
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

      def initialize(index, floors:, settings_for_pair:)
        @index = index
        @floors = floors
        @settings_for_pair = settings_for_pair
      end

      def matches
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

      def unit_matches(eligible)
        postings = Hash.new { |hash, digest| hash[digest] = [] }
        eligible.each { |entry| entry.set.each { |digest| postings[digest] << entry } }

        threshold = @floors[:threshold]
        pairs = Set.new
        eligible.each do |entry|
          prefix(entry, threshold).each do |digest|
            postings.fetch(digest, []).each do |other|
              next if other.equal?(entry)

              pairs << (entry.id < other.id ? [entry, other] : [other, entry])
            end
          end
        end

        pairs.sort_by { |a, b| [a.id, b.id] }.filter_map do |a, b|
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
          connect(locations).filter_map { |a, b| judge(a, b, :subtree) unless a.overlaps?(b) }
        end
      end

      def fragment(entry, node)
        Location.new(entry: entry, start_line: node.start_line, end_line: node.end_line, size: node.size,
                     set: node.digests, whole: false, signature: node.digest)
      end

      # Every pair in a small group; a star from the first location in a big
      # one, which is enough to cluster them without a quadratic blowup.
      def connect(locations)
        if locations.size > STAR_ABOVE
          first, *rest = locations
          rest.map { |other| [first, other] }
        else
          locations.combination(2).to_a
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
          next [] if seeds.size < 2 || seeds.size > RUN_SEED_CAP

          seeds.combination(2).filter_map do |(id_a, i), (id_b, j)|
            run = extend_run(sequences[id_a][1].children, sequences[id_b][1].children, i, j)
            next if id_a == id_b && ranges_overlap?(run[0], run[1], run[2])
            next unless seen.add?([id_a, run[0], id_b, run[1], run[2]])

            a = run_location(sequences[id_a][0], sequences[id_a][1].children, run[0], run[2])
            b = run_location(sequences[id_b][0], sequences[id_b][1].children, run[1], run[2])
            judge(a, b, :run) unless a.overlaps?(b)
          end
        end
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
        Location.new(entry: entry, start_line: nodes.first.start_line, end_line: nodes.last.end_line,
                     size: nodes.sum(&:size), set: set, whole: false, signature: Fingerprints.run_digest(nodes))
      end

      def judge(a, b, kind)
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
          [match.a.whole && match.b.whole ? 0 : 1, -match.size, match.a.key, match.b.key]
        end

        kept_by_entries = Hash.new { |hash, key| hash[key] = [] }
        ordered.each_with_object([]) do |match, kept|
          key = [match.a.entry.id, match.b.entry.id].sort
          next if kept_by_entries[key].any? { |bigger| inside?(match, bigger) }

          kept_by_entries[key] << match
          kept << match
        end
      end

      def inside?(match, bigger)
        (bigger.a.contains?(match.a) && bigger.b.contains?(match.b)) ||
          (bigger.a.contains?(match.b) && bigger.b.contains?(match.a))
      end
    end
  end
end
