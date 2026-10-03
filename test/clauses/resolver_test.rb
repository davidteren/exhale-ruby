# frozen_string_literal: true

require "test_helper"
require "clauses/clauses_helper"

class ContractResolverTest < ContractTestCase
  def ref(contract, text)
    (contract.primitives.flat_map(&:covers) + contract.clauses.flat_map(&:references)).find { |r| r.text == text }
  end

  def covers(*refs, name: "p")
    write "contract/#{name}/README.md", "```covers\n#{refs.join("\n")}\n```\n"
  end

  def parallel(*refs, name: "p", file: "duplication.md", heading: "# why")
    write "contract/#{name}/#{file}", "#{heading}\n\n```parallel\n#{refs.join("\n")}\n```\n"
  end

  def test_method_ref_exact
    covers "A::B#go", "A::B.make"
    a = cunit("A::B", "go")
    b = Exhale::Unit.new(kind: :method, identity: "A::B.make", namespace: "A::B", name: "make", path: "x", start_line: 1, end_line: 2, language: :ruby)
    c = cunit("A::B", "other")
    r = resolver([a, b, c])
    assert_empty r.errors
    assert_equal [a], r.units_for(ref(r.instance_variable_get(:@contract), "A::B#go"))
  end

  def test_dsl_units_match_by_identity
    covers "Order.scope(:settled)"
    d = Exhale::Unit.new(kind: :dsl, identity: "Order.scope(:settled)", namespace: "Order", name: "scope(:settled)", path: "x", start_line: 1, end_line: 2, language: :ruby)
    r = resolver([d])
    assert_empty r.errors
  end

  def test_constant_covers_namespace_and_nested
    covers "A::B"
    inside = [cunit("A::B"), cunit("A::B::C"), cunit("A::B::C::D")]
    outside = [cunit("A::BB"), cunit("A"), cunit("X::A::B")]
    r = resolver(inside + outside)
    c = r.instance_variable_get(:@contract)
    assert_equal inside, r.units_for(ref(c, "A::B"))
  end

  def test_constant_glob_star
    covers "Payments::*::Adapter"
    hit1 = cunit("Payments::Stripe::Adapter")
    hit2 = cunit("Payments::Stripe::Adapter::Charge")
    hit3 = cunit("Payments::Paypal::Adapter")
    miss = [cunit("Payments::Adapter"), cunit("Payments::A::B::Adapter"), cunit("Payments::Stripe::Client")]
    r = resolver([hit1, hit2, hit3] + miss)
    assert_equal [hit1, hit2, hit3], r.units_for(ref(r.instance_variable_get(:@contract), "Payments::*::Adapter"))
  end

  def test_constant_glob_double_star_zero_segments
    covers "Payments::**::Adapter"
    hits = [cunit("Payments::Adapter"), cunit("Payments::A::B::Adapter")]
    r = resolver(hits + [cunit("Payments::Other")])
    assert_equal hits, r.units_for(ref(r.instance_variable_get(:@contract), "Payments::**::Adapter"))
  end

  def test_template_glob
    covers "views/payments/*/_form.html.erb", "views/admin/**", "views/**/_row.html.erb"
    t1 = unit("views/payments/stripe/_form.html.erb", kind: :template)
    t2 = unit("views/payments/a/b/_form.html.erb", kind: :template)
    t3 = unit("views/admin/x/y.html.erb", kind: :template)
    t4 = unit("views/admin", kind: :template)
    t5 = unit("views/_row.html.erb", kind: :template)
    t6 = unit("views/a/b/_row.html.erb", kind: :template)
    r = resolver([t1, t2, t3, t4, t5, t6, cunit("Views")])
    c = r.instance_variable_get(:@contract)
    assert_equal [t1], r.units_for(ref(c, "views/payments/*/_form.html.erb"))
    assert_equal [t3], r.units_for(ref(c, "views/admin/**"))
    assert_equal [t5, t6], r.units_for(ref(c, "views/**/_row.html.erb"))
  end

  # Contract: clause/C3
  def test_unknown_references_error
    covers "Nope::Const", "views/none/*"
    parallel "A::B#x", "Nope#m"
    r = resolver([cunit("A::B", "x")])
    msgs = r.errors.map(&:message)
    assert_equal 3, msgs.size
    assert(msgs.all? { |m| m.include?("reference names no unit:") })
    assert(msgs.any? { |m| m.include?("Nope::Const") })
    assert(msgs.any? { |m| m.include?("Nope#m") })
  end

  # Contract: clause/C2
  def test_keeping_clause_two_references
    parallel "A::One", "A::Two"
    a = cunit("A::One")
    b = cunit("A::Two")
    r = resolver([a, b])
    assert_equal "p", r.keeping_clause(a, b).primitive
    assert_equal r.keeping_clause(a, b), r.keeping_clause(b, a)
  end

  # Contract: clause/C2
  def test_keeping_clause_same_single_reference_is_nil
    parallel "A::One", "A::Two"
    a = cunit("A::One", "x")
    a2 = cunit("A::One", "y")
    r = resolver([a, a2, cunit("A::Two")])
    assert_nil r.keeping_clause(a, a2)
    assert_nil r.keeping_clause(a, cunit("Other"))
  end

  # Contract: clause/C2
  def test_keeping_clause_one_glob_two_match_keys
    parallel "Payments::*::Adapter"
    s = cunit("Payments::Stripe::Adapter")
    s2 = cunit("Payments::Stripe::Adapter::Charge")
    p = cunit("Payments::Paypal::Adapter")
    r = resolver([s, s2, p])
    assert r.keeping_clause(s, p)
    assert r.keeping_clause(s2, p)
    assert_nil r.keeping_clause(s, s2)
  end

  # Contract: clause/C2
  def test_keeping_clause_template_glob
    parallel "views/payments/*/_form.html.erb"
    t1 = unit("views/payments/a/_form.html.erb", kind: :template)
    t2 = unit("views/payments/b/_form.html.erb", kind: :template)
    r = resolver([t1, t2])
    assert r.keeping_clause(t1, t2)
    assert_nil r.keeping_clause(t1, t1)
  end

  # Contract: clause/C2
  def test_keeping_clause_first_in_path_line_order
    parallel "A::One", "A::Two", name: "z"
    parallel "A::One", "A::Two", name: "a"
    a = cunit("A::One")
    b = cunit("A::Two")
    assert_equal "a", resolver([a, b]).keeping_clause(a, b).primitive
  end

  # Contract: clause/C2
  def test_overlapping_references_keep_only_across_the_narrower_one
    parallel "Payments", "Payments::Stripe"
    charge = cunit("Payments::Stripe", "charge")
    refund = cunit("Payments::Stripe", "refund")
    generic = cunit("Payments", "pay")
    r = resolver([charge, refund, generic])
    assert_nil r.keeping_clause(charge, refund)
    assert r.keeping_clause(charge, generic)
  end

  # Contract: clause/C2
  # Contract: clause/C4
  def test_overlapping_glob_and_constant_use_most_specific
    parallel "Payments::**", "Payments::Stripe"
    s = cunit("Payments::Stripe", "a")
    s2 = cunit("Payments::Stripe", "b")
    p = cunit("Payments::Paypal", "c")
    r = resolver([s, s2, p])
    assert_nil r.keeping_clause(s, s2)
    assert r.keeping_clause(s, p)
  end

  # Contract: clause/C4
  # Contract: clause/C5
  def test_glob_primitive_beats_broader_constant
    covers "Payments", name: "payments"
    covers "Payments::*::Adapter", name: "provider_adapter"
    write "contract/provider_adapter/duplication.md", "```settings\nthreshold: 0.6\n```\n"
    u = cunit("Payments::Stripe::Adapter", "charge")
    other = cunit("Payments::Stripe::Client", "charge")
    r = resolver([u, other])
    assert_equal "provider_adapter", r.primitive_for(u).name
    assert_equal "payments", r.primitive_for(other).name
    assert_equal 0.6, r.settings_for(u, { threshold: 0.8 })[:threshold]
  end

  # Contract: clause/C4
  # Contract: clause/C2
  def test_specificity_fewer_double_stars_then_name
    covers "A::**::C", name: "z"
    covers "A::*::C", name: "m"
    covers "A::*::C", name: "b"
    u = cunit("A::B::C")
    assert_equal "b", resolver([u]).primitive_for(u).name
    covers "A::**::C", name: "b"
    assert_equal "m", resolver([u]).primitive_for(u).name
  end

  # Contract: clause/C4
  def test_primitive_for_specificity
    covers "A", "A::B", "A::B#go", "Glob::*", name: "alpha"
    covers "A::B", "Glob::*", name: "beta"
    r = resolver([cunit("A::B", "go"), cunit("A::B", "other"), cunit("A::C"), cunit("Glob::X"), cunit("Z")])
    go, other, ac, gx, z = r.instance_variable_get(:@units)
    assert_equal "alpha", r.primitive_for(go).name
    assert_equal "alpha", r.primitive_for(other).name # tie on text: name order
    assert_equal "alpha", r.primitive_for(ac).name
    assert_equal "alpha", r.primitive_for(gx).name
    assert_nil r.primitive_for(z)
  end

  # Value: protects=a method reference is more specific than any constant reference, even when the method's name holds a `*`; fails_when=specificity scores a method reference like a constant and `Vector#*` counts one literal segment fewer than `Vector`; why_new=no reference named an operator method; seam=none
  # Contract: clause/C4
  def test_a_method_reference_beats_its_constant_even_for_an_operator
    covers "Vector#*", name: "z_operators"
    covers "Vector", name: "a_vectors"
    times = cunit("Vector", "*")
    r = resolver([times, cunit("Vector", "dot")])

    assert_equal "z_operators", r.primitive_for(times).name
  end

  # Value: protects=units_for lists the units a reference matches in source order; fails_when=a glob over several prefixes lists units in prefix order; why_new=glob tests listed units whose prefix order and source order agree; seam=none
  def test_units_for_lists_units_in_source_order
    covers "Payments::*"
    units = [cunit("Payments::Stripe", "a"), cunit("Payments::Paypal", "b"), cunit("Payments::Stripe", "c")]
    r = resolver(units)

    assert_equal units, r.units_for(ref(r.instance_variable_get(:@contract), "Payments::*"))
  end

  # Contract: clause/C4
  def test_primitive_for_longer_constant_beats_shorter
    covers "A", name: "outer"
    covers "A::B", name: "inner"
    r = resolver([cunit("A::B")])
    assert_equal "inner", r.primitive_for(r.instance_variable_get(:@units).first).name
  end

  # Contract: clause/C4
  def test_primitive_for_method_beats_constant
    covers "A::B", name: "inner"
    covers "A::B#go", name: "m"
    r = resolver([cunit("A::B", "go")])
    assert_equal "m", r.primitive_for(r.instance_variable_get(:@units).first).name
  end

  # Contract: clause/C5
  def test_settings_for_and_pair
    covers "A", name: "strict"
    covers "B", name: "loose"
    covers "C", name: "plain"
    write "contract/strict/duplication.md", "```settings\nthreshold: 0.6\nmin-lines: 5\n```\n"
    write "contract/loose/duplication.md", "```settings\nthreshold: 0.9\nmin-lines: 2\n```\n"
    a = cunit("A")
    b = cunit("B")
    c = cunit("C")
    z = cunit("Z")
    r = resolver([a, b, c, z])
    defaults = { threshold: 0.8, min_lines: 4, min_nodes: 20 }
    assert_equal({ threshold: 0.6, min_lines: 5, min_nodes: 20 }, r.settings_for(a, defaults))
    assert_equal defaults, r.settings_for(z, defaults)
    assert_equal({ threshold: 0.6, min_lines: 2, min_nodes: 20 }, r.settings_for_pair(a, b, defaults))
    assert_equal({ threshold: 0.8, min_lines: 4, min_nodes: 20 }, r.settings_for_pair(c, z, defaults))
    assert_equal({ threshold: 0.6, min_lines: 4, min_nodes: 20 }, r.settings_for_pair(a, z, defaults))
  end

  # Value: protects=glob matching answers a plain true or false for an empty namespace; fails_when=an empty segment list raises, or a trailing `**` after a miss answers nil instead of false; why_new=resolver tests only matched non-empty namespaces; seam=none
  # Contract: clause/C6
  def test_glob_matching_an_empty_namespace_answers_true_or_false
    seg_match = Exhale::Contract::Reference.method(:seg_match?)
    assert_equal true, seg_match.call(["**"], [])
    assert_equal false, seg_match.call(["A"], [])
    assert_equal false, seg_match.call(["**", "A"], [])
    assert_equal true, seg_match.call(["**", "A"], ["A"])
  end

  # Contract: clause/C6
  def test_repeated_double_stars_match_in_linear_time
    glob = (["**"] * 40).join("::") + "::Never"
    covers glob
    units = [cunit((["Ns"] * 40).join("::"))]
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = resolver(units)
    assert_equal 1, r.errors.size
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 1
  end

  def test_scales
    covers "N5::**"
    units = (0...20_000).map { |i| cunit("N#{i % 500}::K#{i % 7}", "m#{i}") }
    parallel "N1::K1", "N2::K2"
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    r = resolver(units)
    r.errors
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - t, :<, 3
  end
end
