# frozen_string_literal: true

require_relative "fingerprints"

module Exhale
  module Dry
    # One top-level unit in the index: the unit, its fingerprinted tree, its
    # fingerprint set and that set's total weight.
    Entry = Struct.new(:id, :unit, :tree, :set, :total, keyword_init: true) do
      # Identity is the id. Comparing whole fingerprint sets would be slow and
      # says nothing an id doesn't.
      def ==(other)
        other.is_a?(Entry) && id == other.id
      end
      alias_method :eql?, :==

      def hash
        id.hash
      end
    end

    # Fingerprint counts and weights for one tree. Weights always come from
    # the tree being checked, so the verdict reads nothing but the commit.
    class Index
      attr_reader :entries, :weights

      def initialize(entries)
        @entries = entries
        @counts = Hash.new(0)
        entries.each { |entry| entry.set.each { |digest| @counts[digest] += 1 } }
        @weights = Weights.new(@counts)
        entries.each { |entry| entry.total = weight_of(entry.set) }
      end

      def count(digest)
        @counts.fetch(digest, 0)
      end

      def weight_of(set)
        set.sum { |digest| @weights[digest] }
      end

      # Rarity-weighted Jaccard similarity, as an exact Rational so the
      # threshold comparison never depends on floating point.
      def score(set_a, total_a, set_b, total_b)
        shared = shared_weight(set_a, set_b)
        union = total_a + total_b - shared
        union.zero? ? Rational(0) : Rational(shared, union)
      end

      private

      def shared_weight(set_a, set_b)
        small, large = set_a.size <= set_b.size ? [set_a, set_b] : [set_b, set_a]
        small.sum { |digest| large.include?(digest) ? @weights[digest] : 0 }
      end
    end
  end
end
