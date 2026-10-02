# frozen_string_literal: true

require "digest"
require "set"
require "bigdecimal"
require "bigdecimal/math"

module Exhale
  module Dry
    # A normalized node with its structural digest. Equal structure gives an
    # equal digest, computed bottom up from the node's kind, label and its
    # children's digests, so nothing gets printed.
    class FNode
      attr_reader :digest, :size, :start_line, :end_line, :children

      def initialize(digest, size, start_line, end_line, children, sequence)
        @digest = digest
        @size = size
        @start_line = start_line
        @end_line = end_line
        @children = children
        @sequence = sequence
      end

      def sequence?
        @sequence
      end

      def lines
        end_line - start_line + 1
      end

      # Preorder, so a parent always comes before its descendants.
      def each_node(&block)
        return enum_for(:each_node) unless block

        stack = [self]
        until stack.empty?
          node = stack.pop
          yield node
          node.children.reverse_each { |child| stack.push(child) }
        end
      end

      # The fingerprint set: the digest of every subtree.
      def digests
        set = Set.new
        each_node { |node| set << node.digest }
        set
      end
    end

    module Fingerprints
      module_function

      # Digests are the first 8 bytes of SHA-256, which is unseeded and the
      # same in every process. Ruby's own String#hash is seeded per process,
      # so it would break the on-disk cache and determinism both.
      def build(shape)
        children = shape.children.map { |child| build(child) }
        payload = +"#{shape.kind}\u0000#{shape.label}\u0000"
        children.each { |child| payload << [child.digest].pack("Q>") }
        digest = Digest::SHA256.digest(payload).unpack1("Q>")
        size = 1 + children.sum(&:size)
        FNode.new(digest, size, shape.start_line, shape.end_line, children, shape.sequence ? true : false)
      end

      # The digest of a run of sibling nodes, used for statement-run fragments.
      def run_digest(nodes)
        Digest::SHA256.digest(nodes.map(&:digest).pack("Q>*")).unpack1("Q>")
      end
    end

    # w(f) = ln(1 + C / df(f)), stored as fixed-point integers.
    #
    # A weight depends only on its own fingerprint's count, never on the size
    # of the codebase, which is what keeps an incremental sweep exact. The log
    # comes from BigDecimal rather than Math.log: libm can differ in the last
    # bit between platforms, and BigDecimal's arithmetic is the same
    # everywhere.
    class Weights
      C = 1000
      SCALE = 1_000_000
      PRECISION = 30

      def initialize(counts)
        @counts = counts
        @by_count = {}
      end

      def [](digest)
        for_count(@counts.fetch(digest, 1))
      end

      def for_count(count)
        @by_count[count] ||= begin
          ratio = BigDecimal(1) + BigDecimal(C).div(count, PRECISION)
          (BigMath.log(ratio, PRECISION) * SCALE).round
        end
      end
    end
  end
end
