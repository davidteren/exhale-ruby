# frozen_string_literal: true

require "test_helper"
require "digest"
require "bigdecimal"
require "bigdecimal/math"
require "open3"
require "rbconfig"
require "exhale/shape"
require "exhale/unit"
require "exhale/dry/fingerprints"
require "exhale/dry/index"
require "exhale/dry/matcher"

# Fingerprint's obligations (contract/fingerprint/README.md), checked
# against their own definitions rather than against the code's.
class FingerprintContractTest < Minitest::Test
  def shape(kind, label = nil, children = [], line: 1)
    Exhale::Shape.new(kind: kind, label: label, children: children, start_line: line, end_line: line, sequence: false)
  end

  def tree
    shape("call_node", "map", [shape(":local"), shape("block_node", nil, [shape(":literal")])])
  end

  # The first 8 bytes of SHA-256 over kind, label and the child digests.
  def by_definition(node)
    payload = "#{node.kind}\u0000#{node.label}\u0000".b + node.children.map { |c| [by_definition(c)].pack("Q>") }.join.b
    Digest::SHA256.digest(payload)[0, 8].unpack1("Q>")
  end

  # Contract: fingerprint/F1
  def test_a_digest_is_the_first_eight_bytes_of_sha256_over_kind_label_and_children
    built = Exhale::Dry::Fingerprints.build(tree)

    assert_equal by_definition(tree), built.digest
    assert_equal by_definition(tree.children[1]), built.children[1].digest
  end

  # A label is any method name Ruby allows, Unicode included. The payload is
  # bytes: the UTF-8 of kind and label, then the packed child digests.
  # Contract: fingerprint/F1
  def test_a_unicode_label_is_digested_as_its_utf8_bytes
    unicode = shape("call_node", "café", [shape(":local"), shape("block_node", nil, [shape(":literal")])])

    assert_equal by_definition(unicode), Exhale::Dry::Fingerprints.build(unicode).digest
    refute_equal Exhale::Dry::Fingerprints.build(tree).digest, Exhale::Dry::Fingerprints.build(unicode).digest
  end

  # Contract: fingerprint/F1
  def test_a_unicode_method_name_in_source_fingerprints
    require "exhale/units/ruby"
    require "exhale/dry/normalizer"
    unit = Exhale::Units::Ruby.extract("class A\n  def total(x)\n    café(x).map { |y| y + 1 }\n  end\nend\n", "a.rb").first

    built = Exhale::Dry::Fingerprints.build(Exhale::Dry::Normalizer.normalize(unit))

    assert_operator built.size, :>, 3
  end

  # Contract: fingerprint/F1
  def test_digests_are_equal_in_another_process
    script = <<~'RUBY'
      require "exhale/shape"
      require "exhale/dry/fingerprints"
      leaf = ->(kind) { Exhale::Shape.new(kind: kind, label: nil, children: [], start_line: 1, end_line: 1, sequence: false) }
      block = Exhale::Shape.new(kind: "block_node", label: nil, children: [leaf.(":literal")], start_line: 1, end_line: 1, sequence: false)
      root = Exhale::Shape.new(kind: "call_node", label: "map", children: [leaf.(":local"), block], start_line: 1, end_line: 1, sequence: false)
      print Exhale::Dry::Fingerprints.build(root).digest
    RUBY
    lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.capture3({ "LANG" => "C", "TZ" => "Pacific/Chatham" }, RbConfig.ruby, "-I", lib, "-e", script)

    assert status.success?, err
    assert_equal Exhale::Dry::Fingerprints.build(tree).digest, Integer(out)
  end

  # Contract: fingerprint/F2
  def test_a_weight_is_ln_of_one_plus_a_thousand_over_count_in_fixed_point
    weights = Exhale::Dry::Weights.new({})

    [1, 2, 3, 7, 50, 999, 1000, 123_456].each do |count|
      exact = BigMath.log(BigDecimal(1) + BigDecimal(1000).div(count, 30), 30) * 1_000_000
      assert_equal exact.round, weights.for_count(count), "count #{count}"
      assert_kind_of Integer, weights.for_count(count)
    end
  end

  # Contract: fingerprint/F2
  def test_a_weight_depends_on_nothing_but_its_own_count
    built = Exhale::Dry::Fingerprints.build(tree)
    small = Exhale::Dry::Weights.new({ built.digest => 3 })
    big = Exhale::Dry::Weights.new({ built.digest => 3 }.merge((1..5000).to_h { |i| [i, i] }))

    assert_equal small[built.digest], big[built.digest]
    assert_equal small.for_count(3), small[built.digest]
    assert_equal small.for_count(1), small[12_345]
  end

  # The count behind a weight is how many units of the tree being checked
  # hold the fingerprint.
  # Contract: fingerprint/F2
  def test_an_index_weighs_each_fingerprint_by_how_many_units_hold_it
    shared = shape(":local")
    trees = %w[charge refund void].map { |name| Exhale::Dry::Fingerprints.build(shape("call_node", name, [shared])) }
    entries = trees.each_with_index.map { |t, id| Exhale::Dry::Entry.new(id: id, unit: nil, tree: t, set: t.digests) }
    index = Exhale::Dry::Index.new(entries)
    weights = Exhale::Dry::Weights.new({})
    local = Exhale::Dry::Fingerprints.build(shared).digest

    assert_equal 3, index.count(local)
    assert_equal 1, index.count(trees[0].digest)
    assert_equal weights.for_count(3), index.weights[local]
    assert_equal weights.for_count(1), index.weights[trees[0].digest]
    assert_equal weights.for_count(3) + weights.for_count(1), entries[0].total
  end

  # Contract: fingerprint/F3
  def test_a_score_is_an_exact_rational
    a = Exhale::Dry::Fingerprints.build(tree)
    b = Exhale::Dry::Fingerprints.build(shape("call_node", "select", [shape(":local")]))
    entries = [a, b].each_with_index.map { |t, id| Exhale::Dry::Entry.new(id: id, unit: nil, tree: t, set: t.digests) }
    index = Exhale::Dry::Index.new(entries)

    score = index.score(entries[0].set, entries[0].total, entries[1].set, entries[1].total)
    assert_kind_of Rational, score
    shared = index.weights[shape_digest(":local")]
    assert_equal Rational(shared, entries[0].total + entries[1].total - shared), score
  end

  def shape_digest(kind)
    Exhale::Dry::Fingerprints.build(shape(kind)).digest
  end

  # A pair scoring exactly the threshold meets it, and the smallest step
  # above its score misses it.
  # Contract: fingerprint/F3
  def test_a_pair_meets_a_threshold_by_exact_comparison
    a = Exhale::Dry::Fingerprints.build(statements(%w[charge refund void settle capture]))
    b = Exhale::Dry::Fingerprints.build(statements(%w[charge refund void settle authorize]))
    entries = [a, b].each_with_index.map do |t, id|
      unit = Exhale::Unit.new(kind: :method, identity: "M#{id}#run", path: "m#{id}.rb", start_line: 1, end_line: 10,
                              language: :ruby)
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: t, set: t.digests)
    end
    index = Exhale::Dry::Index.new(entries)
    score = index.score(entries[0].set, entries[0].total, entries[1].set, entries[1].total)
    at = { threshold: score, min_lines: 1, min_nodes: 1 }
    above = at.merge(threshold: score + Rational(1, 10**30))

    assert_operator score, :<, 1
    assert_equal 1, Exhale::Dry::Matcher.new(index, floors: at, settings_for_pair: ->(*) { at }).matches.count { |m| m.kind == :unit }
    assert_equal 0, Exhale::Dry::Matcher.new(index, floors: at, settings_for_pair: ->(*) { above }).matches.count { |m| m.kind == :unit }
  end

  def statements(names)
    children = names.each_with_index.map { |name, i| shape("call_node", name, [shape(":local", line: i + 2)], line: i + 2) }
    Exhale::Shape.new(kind: "def_node", label: nil, start_line: 1, end_line: 10, sequence: false,
                      children: [Exhale::Shape.new(kind: "statements_node", label: nil, children: children, start_line: 2,
                                                   end_line: 9, sequence: true)])
  end
end
