# frozen_string_literal: true

require "test_helper"
require "exhale/shape"
require "exhale/dry/fingerprints"
require "exhale/dry/index"

class FingerprintsTest < Minitest::Test
  def shape(kind, label = nil, children = [], line: 1, sequence: false)
    Exhale::Shape.new(kind: kind, label: label, children: children, start_line: line, end_line: line, sequence: sequence)
  end

  def build(tree)
    Exhale::Dry::Fingerprints.build(tree)
  end

  # Contract: fingerprint/F1
  def test_equal_structure_gives_equal_digests_whatever_the_lines
    a = shape("call_node", "map", [shape(":local", line: 3)], line: 3)
    b = shape("call_node", "map", [shape(":local", line: 9)], line: 9)

    assert_equal build(a).digest, build(b).digest
  end

  def test_labels_and_child_order_change_the_digest
    base = build(shape("call_node", "map", [shape(":local"), shape(":literal")])).digest

    refute_equal base, build(shape("call_node", "select", [shape(":local"), shape(":literal")])).digest
    refute_equal base, build(shape("call_node", "map", [shape(":literal"), shape(":local")])).digest
  end

  # A digest is part of the on-disk cache and of every verdict, so it must be
  # the same in every process and on every platform.
  # Contract: fingerprint/F1
  def test_digests_are_pinned
    tree = build(shape("call_node", "map", [shape(":local")]))

    assert_equal 4_089_009_902_997_379_658, tree.digest
    assert_equal 2, tree.size
    assert_equal 2, tree.digests.size
  end

  # Contract: fingerprint/F2
  def test_weights_are_pinned_fixed_point_integers
    weights = Exhale::Dry::Weights.new({})

    assert_equal 6_908_755, weights.for_count(1)
    assert_equal 6_216_606, weights.for_count(2)
    assert_equal 693_147, weights.for_count(1000)
    assert_equal 95_310, weights.for_count(10_000)
  end

  # Contract: fingerprint/F3
  def test_score_is_rarity_weighted_jaccard_as_a_rational
    rare_a = build(shape("call_node", "charge", [shape(":local")]))
    rare_b = build(shape("call_node", "refund", [shape(":local")]))
    entries = [rare_a, rare_a, rare_b].each_with_index.map do |tree, id|
      Exhale::Dry::Entry.new(id: id, unit: nil, tree: tree, set: tree.digests)
    end
    index = Exhale::Dry::Index.new(entries)
    a, b, c = entries

    assert_equal Rational(1), index.score(a.set, a.total, b.set, b.total)
    shared = index.weights[shape_digest(":local")]
    assert_equal Rational(shared, a.total + c.total - shared), index.score(a.set, a.total, c.set, c.total)
  end

  # Value: protects=a shape's line count spans its first and last line inclusive; fails_when=lines is off by one or subtracts the wrong way; why_new=nothing in the suite read Shape#lines; seam=none
  def test_a_shape_counts_its_lines_inclusively
    assert_equal 1, shape("call_node").lines
    assert_equal 4, Exhale::Shape.new(kind: "def_node", label: nil, children: [], start_line: 3, end_line: 6, sequence: false).lines
  end

  # Value: protects=an index entry's identity is its id alone, so comparing or hashing entries never walks their fingerprint sets; fails_when=two entries with one id compare unequal, or entries with different ids compare equal; why_new=nothing in the suite compared entries; seam=none
  def test_entries_are_equal_exactly_when_their_ids_are
    one = Exhale::Dry::Entry.new(id: 1, set: Set[1])
    same_id = Exhale::Dry::Entry.new(id: 1, set: Set[2])
    other = Exhale::Dry::Entry.new(id: 2, set: Set[1])

    assert_equal one, same_id
    assert one.eql?(same_id)
    assert_equal one.hash, same_id.hash
    refute_equal one, other
    refute_equal one, Struct.new(:id).new(1)
  end

  # Value: protects=a fingerprint node keeps its shape's line span and whether it is a sequence; fails_when=a node's line count is off, or every node reads as a statement sequence and seeds runs inside argument lists; why_new=nothing read FNode#lines or a non-sequence node's flag directly; seam=none
  def test_a_node_keeps_its_line_count_and_sequence_flag
    node = build(Exhale::Shape.new(kind: "def_node", label: nil, children: [], start_line: 3, end_line: 6, sequence: false))
    assert_equal 4, node.lines
    refute node.sequence?
    assert build(shape("statements_node", sequence: true)).sequence?
  end

  def shape_digest(kind)
    build(shape(kind)).digest
  end
end
