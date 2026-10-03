# frozen_string_literal: true

require "test_helper"
require "exhale/unit"
require "exhale/units/ruby"
require "exhale/dry/normalizer"
require "exhale/dry/fingerprints"
require "exhale/dry/index"
require "exhale/dry/matcher"

class MatcherTest < Minitest::Test
  SETTINGS = { threshold: Rational(4, 5), min_lines: 4, min_nodes: 20 }.freeze

  def entries_for(sources)
    units = sources.each_with_index.flat_map { |source, i| Exhale::Units::Ruby.extract(source, "app/models/m#{i}.rb") }
    units.each_with_index.map do |unit, id|
      tree = Exhale::Dry::Fingerprints.build(Exhale::Dry::Normalizer.normalize(unit))
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
    end
  end

  def matcher(index)
    Exhale::Dry::Matcher.new(index, floors: SETTINGS, settings_for_pair: ->(_a, _b) { SETTINGS })
  end

  # Families of methods: each family starts from one body and its members
  # swap out zero, one or two statements, so pairs land on both sides of the
  # threshold. The seed keeps the corpus fixed.
  def corpus
    random = Random.new(42)
    statements = [
      "total = items.sum { |i| i.amount }", "tax = total * rate_for(region)", "notify(user, total)",
      "log.info(total.to_s)", "return if items.empty?", "items.each { |i| i.touch }",
      "cache.write(key, total)", "raise Error unless valid?", "audit!(user, :checked)", "self.count += 1",
      "mailer.deliver_later(user)", "items.select(&:stale?).each(&:refresh!)", "lock.synchronize { flush }"
    ]
    n = 0
    (0...8).flat_map do
      body = Array.new(7) { statements.sample(random: random) }
      (0...5).map do
        variant = body.dup
        random.rand(3).times { variant[random.rand(variant.size)] = statements.sample(random: random) }
        n += 1
        "class M#{n}\n  def run(items, user)\n    #{variant.join("\n    ")}\n  end\nend\n"
      end
    end
  end

  # Every pair a full comparison scores at the threshold lands in one
  # component, and no match the matcher reports scores below it. Identical
  # units join their group as a star, so components are the observable unit.
  # Contract: matcher/M1
  def test_prefix_filtering_connects_exactly_the_pairs_brute_force_finds
    entries = entries_for(corpus)
    index = Exhale::Dry::Index.new(entries)
    eligible = entries.select { |e| e.unit.lines >= 4 && e.tree.size >= 20 }

    brute = eligible.combination(2).select do |a, b|
      index.score(a.set, a.total, b.set, b.total) >= SETTINGS[:threshold]
    end
    found = matcher(index).send(:unit_matches, eligible)
    component = components(found.map { |m| [m.a.entry.id, m.b.entry.id] })

    refute_empty brute
    brute.each { |a, b| assert_equal component[a.id], component[b.id], "#{a.unit.identity} ~ #{b.unit.identity}" }
    found.each { |m| assert_operator m.score, :>=, SETTINGS[:threshold] }
    brute_components = components(brute.map { |a, b| [a.id, b.id] })
    assert_equal brute_components.values.uniq.size, component.values.uniq.size
  end

  def components(edges)
    parent = {}
    find = ->(x) { parent[x] ||= x; parent[x] == x ? x : (parent[x] = find.(parent[x])) }
    edges.each { |a, b| parent[find.(a)] = find.(b) }
    parent.keys.to_h { |x| [x, find.(x)] }
  end

  # Contract: matcher/M3
  def test_a_run_lifted_out_of_the_middle_of_a_method_is_found
    shared = "subtotal = lines.sum { |l| l.amount * l.quantity }\n    " \
             "tax = subtotal * rate_for(region)\n    " \
             "discount = lines.select(&:discounted?).sum(&:discount)\n    " \
             "ledger.post(subtotal + tax - discount)"
    a = "class A\n  def settle(lines)\n    prepare!\n    #{shared}\n    archive!\n  end\nend\n"
    b = "class B\n  def close(rows)\n    validate(rows)\n    lock!\n    #{shared.gsub('lines', 'rows')}\n    " \
        "mail(rows)\n  end\nend\n"
    entries = entries_for([a, b])
    index = Exhale::Dry::Index.new(entries)

    runs = matcher(index).matches.select { |m| m.kind == :run }

    assert_equal 1, runs.size
    assert_equal [4, 7], [runs[0].a.start_line, runs[0].a.end_line]
    assert_equal [5, 8], [runs[0].b.start_line, runs[0].b.end_line]
  end

  # Value: protects=a run grows past one mismatched statement and stops at the second, going forward; fails_when=the run spends its one mismatch and keeps skipping, swallowing statements that differ; why_new=no test had two mismatches in a run; seam=none
  # Contract: matcher/M3
  def test_a_run_spends_one_mismatch_going_forward
    shared = %w[alpha beta gamma delta]
    left = pad("a", 6) + shared + %w[left_one epsilon left_two zeta] + pad("c", 6)
    right = pad("b", 6) + shared + %w[right_one epsilon right_two zeta] + pad("d", 6)

    # Line 3 is the first statement; the run is alpha..epsilon.
    assert_equal [[[9, 14], [9, 14]]], run_lines(left, right)
  end

  # Value: protects=a run grows past one mismatched statement and stops at the second, going backward; fails_when=the backward walk never spends its mismatch and swallows statements that differ; why_new=no test had two mismatches before a run's seed; seam=none
  # Contract: matcher/M3
  def test_a_run_spends_one_mismatch_going_backward
    left = pad("a", 6) + %w[alpha left_one beta left_two gamma delta epsilon zeta] + pad("c", 6)
    right = pad("b", 6) + %w[alpha right_one beta right_two gamma delta epsilon zeta] + pad("d", 6)

    # The run is beta..zeta: one mismatch spent, the second one stops it.
    assert_equal [[[11, 16], [11, 16]]], run_lines(left, right)
  end

  # Value: protects=skipping a mismatch backward compares the statements just before it on both sides; fails_when=the skip compares a statement after the mismatch with one before it, so a statement that repeats nearby lets the run swallow two mismatches in a row; why_new=the other run tests never repeat a statement around a mismatch; seam=none
  # Contract: matcher/M3
  def test_a_run_never_spans_two_adjacent_mismatches
    tail = %w[gamma delta epsilon zeta]
    cases = [[%w[left_only left_x] + tail, %w[gamma right_x] + tail],
             [%w[gamma left_x] + tail, %w[right_only right_x] + tail]]

    cases.each do |left, right|
      # The run is gamma..zeta after the mismatch, never the two before it.
      assert_equal [[[11, 14], [11, 14]]], run_lines(pad("a", 6) + left + pad("c", 6), pad("b", 6) + right + pad("d", 6))
    end
  end

  # Value: protects=every run extend_run grows stays inside both sequences, keeps one offset, holds at most one mismatched statement with matching ends, and stops only where it can't grow, forward first and then backward with the budget left; fails_when=an index or bound in the growth loops is off, so a run reads past an end, wraps to the other end, skips two mismatches, or stops early; why_new=the run tests only used aligned sequences with padding, so offsets, ends and wrap-around had no test; seam=extend_run called directly with digest stand-ins
  # Contract: matcher/M3
  def test_runs_grow_as_far_as_one_mismatch_allows_on_random_sequences
    node = Struct.new(:digest)
    random = Random.new(7)
    extender = Exhale::Dry::Matcher.new(nil, floors: {}, settings_for_pair: nil)
    checked = 0

    800.times do
      left = Array.new(random.rand(3..11)) { node.new(random.rand(3)) }
      right = Array.new(random.rand(3..11)) { node.new(random.rand(3)) }
      seeds(left, right).each do |i, j|
        start_a, start_b, length = extender.send(:extend_run, left, right, i, j)
        back = i - start_a
        same = ->(k) { left[start_a + k].digest == right[start_b + k].digest }
        missed = (0...length).reject(&same)

        assert_equal back, j - start_b
        assert_operator back, :>=, 0
        assert_operator start_a, :>=, 0
        assert_operator start_b, :>=, 0
        assert_operator start_a + length, :<=, left.size
        assert_operator start_b + length, :<=, right.size
        assert_operator length, :>=, back + 3
        assert_operator missed.size, :<=, 1
        assert same.call(0)
        assert same.call(length - 1)

        forward_spent = missed.count { |k| k >= back + 3 }
        refute grows?(left, right, start_a + length, start_b + length, 1, 1 - forward_spent), "grows forward"
        refute grows?(left, right, start_a - 1, start_b - 1, -1, 1 - missed.size), "grows backward"
        checked += 1
      end
    end

    assert_operator checked, :>, 600
  end

  # Value: protects=the exact core around a seed is the longest run of identical statements through it, grown forward and then backward, inside both sequences and at one offset; fails_when=an index or bound in either growth loop is off, so the core stops early, reads the wrong side, or wraps to the other end of a sequence; why_new=the core was only exercised through whole-matcher fixtures that never put a seed at the start of a sequence or compared both sides' offsets; seam=exact_core called directly with digest stand-ins
  # Contract: matcher/M3
  def test_the_exact_core_is_the_longest_identical_run_through_the_seed
    node = Struct.new(:digest)
    random = Random.new(11)
    finder = Exhale::Dry::Matcher.new(nil, floors: {}, settings_for_pair: nil)
    checked = 0

    1500.times do
      left = Array.new(random.rand(3..11)) { node.new(random.rand(2)) }
      right = Array.new(random.rand(3..11)) { node.new(random.rand(2)) }
      seeds(left, right).each do |i, j|
        # The diagonal through the seed: where each aligned pair matches.
        reach = (-[i, j].min...[left.size - i, right.size - j].min).to_a
        equal = reach.to_h { |d| [d, left[i + d].digest == right[j + d].digest] }
        low = (reach.first..0).to_a.reverse.take_while { |d| equal[d] }.last
        high = (0..reach.last).take_while { |d| equal[d] }.last
        back = -low
        ahead = high + 1

        assert_equal [i - back, j - back, back + ahead], finder.send(:exact_core, left, right, i, j)
        checked += 1
      end
    end

    assert_operator checked, :>, 1000
  end

  # Value: protects=two copies of a run sitting back to back in one method are found; fails_when=runs that touch end to start count as overlapping and are skipped; why_new=the repeated-run test kept a statement between the copies; seam=none
  # Contract: matcher/M5
  def test_back_to_back_copies_of_a_run_in_one_method_are_found
    shared = %w[alpha beta gamma delta]
    source = method_source("A", calls(pad("a", 6) + shared + shared + pad("c", 6)))

    runs = matches_for([source]).select { |m| m.kind == :run }

    assert_equal [[[9, 12], [13, 16]]], runs.map { |m| spans(m) }
  end

  # Value: protects=a method body of exactly three statements seeds runs; fails_when=a sequence needs more than three statements before it seeds; why_new=every run test used longer bodies; seam=none
  # Contract: matcher/M3
  def test_a_body_of_exactly_three_statements_seeds_a_run
    settings = { threshold: Rational(1, 2), min_lines: 3, min_nodes: 15 }

    assert_equal [[[3, 5], [9, 11]]], run_lines(%w[alpha beta gamma], pad("b", 6) + %w[alpha beta gamma] + pad("d", 6), settings)
  end

  # Value: protects=runs come only from statement sequences, never from argument lists; fails_when=any node with three children seeds runs, so matching arguments across two calls read as a copied run; why_new=no test put a run-shaped argument list in front of the matcher; seam=none
  # Contract: matcher/M3
  def test_matching_arguments_are_not_a_run_of_statements
    args = ->(last) { "notify(\n      #{calls(%w[alpha beta gamma delta] + [last], ",\n      ")}\n    )" }
    a = method_source("A", "#{calls(pad('a', 6))}\n    #{args.call('left_x')}")
    b = method_source("B", "#{calls(pad('b', 6))}\n    #{args.call('right_x')}")

    assert_empty(matches_for([a, b], { threshold: Rational(9, 10), min_lines: 4, min_nodes: 20 }).select { |m| m.kind == :run })
  end

  # Value: protects=both sides of a run must clear the size floors; fails_when=a run counts when only one side is big enough, so a copy squeezed onto one line is reported; why_new=every run test kept one statement per line on both sides; seam=none
  # Contract: matcher/M6
  def test_a_run_squeezed_onto_one_line_is_too_small_to_report
    shared = %w[alpha beta gamma delta]
    a = method_source("A", calls(pad("a", 6) + shared + pad("c", 6)))
    b = method_source("B", "#{calls(pad('b', 6))}\n    #{calls(shared, '; ')}\n    #{calls(pad('d', 6))}")

    assert_empty(matches_for([a, b]).select { |m| m.kind == :run })
  end

  # Value: protects=a match is dropped only when both of its sides sit inside a larger match's sides; fails_when=one side inside the larger match is enough, so a second copy elsewhere in the other unit disappears; why_new=the pruning tests only had matches wholly inside or wholly outside; seam=none
  # Contract: matcher/M4
  def test_a_match_with_one_side_outside_the_larger_match_stays
    long = %w[alpha beta gamma delta epsilon zeta]
    a = method_source("A", calls(pad("a", 6) + long + pad("c", 6)))
    b = method_source("B", calls(pad("b", 6) + long + pad("d", 6) + %w[beta gamma delta epsilon]))

    runs = matches_for([a, b]).select { |m| m.kind == :run && m.a.path != m.b.path }.map { |m| spans(m) }

    assert_includes runs, [[9, 14], [9, 14]]
    assert_includes runs, [[10, 13], [21, 24]]
  end

  # Value: protects=the size floors are inclusive for whole units and for fragments; fails_when=a unit or fragment exactly at min-lines or min-nodes is dropped; why_new=no test put anything exactly on a floor; seam=none
  # Contract: matcher/M6
  def test_units_and_fragments_exactly_at_the_floors_match
    unit = "class A\n  def a(v)\n    prepare(v)\n    v.save!\n  end\nend\n"
    entries = entries_for([unit, unit.sub("class A", "class B")])
    floors = { threshold: Rational(1), min_lines: entries[0].unit.lines, min_nodes: entries[0].tree.size }
    assert_equal [:unit], matches_for([unit, unit.sub("class A", "class B")], floors).map(&:kind)

    branch = "if v.ok?\n      go(v, v.id)\n      stop(v, v.id)\n    end"
    a = "class A\n  def a(v)\n    prepare(v)\n    #{branch}\n  end\nend\n"
    b = "class B\n  def b(v)\n    other(v)\n    more(v)\n    #{branch}\n  end\nend\n"
    node = entries_for([a]).first.tree.each_node.select { |n| [n.start_line, n.end_line] == [4, 7] }.max_by(&:size)
    floors = { threshold: Rational(1), min_lines: 4, min_nodes: node.size }
    assert_equal [:subtree], matches_for([a, b], floors).map(&:kind)
  end

  # Value: protects=a pair whose score equals the threshold exactly is a match, even when the totals bound is tight; fails_when=the totals bound rejects a pair it should only rule out when the smaller total is below threshold times the larger; why_new=no test put a pair exactly on the threshold; seam=none
  # Contract: fingerprint/F3
  def test_a_pair_exactly_at_the_threshold_matches
    inner = "def a(v)\n      x(v)\n      y(v)\n      z(v)\n    end"
    a = "class A\n  #{inner.gsub("\n  ", "\n")}\nend\n"
    b = "class B\n  def b(v)\n    #{inner}\n    w(v)\n  end\nend\n"
    entries = entries_for([a, b])
    Exhale::Dry::Index.new(entries)
    exact = Rational(entries[0].total, entries[1].total)
    settings = { threshold: exact, min_lines: 1, min_nodes: 1 }

    unit = matches_for([a, b], settings).select { |m| m.kind == :unit }

    assert_equal [exact], unit.map(&:score)
  end

  # Value: protects=a group of up to 100 copies of one fragment pairs every copy, and a bigger group connects as a star; fails_when=the star starts at exactly 100 copies, so the largest all-pairs group loses its pairs; why_new=the star cap had no test at its edge; seam=none
  # Contract: matcher/M7
  def test_up_to_a_hundred_fragment_copies_pair_all_and_more_form_a_star
    branch = "if v.ok?\n      go(v, v.id)\n      stop(v, v.id)\n      log(v.id)\n    end"
    sources = ->(count) do
      (1..count).map do |n|
        steps = (1..6).map { |k| "step_#{n}_#{k}(v)" }.join("\n    ")
        "class M#{n}\n  def run(v)\n    #{steps}\n    #{branch}\n  end\nend\n"
      end
    end
    settings = { threshold: Rational(9, 10), min_lines: 4, min_nodes: 15 }
    subtree = ->(count) { matches_for(sources.call(count), settings).count { |m| m.kind == :subtree } }

    assert_equal 100 * 99 / 2, subtree.call(100)
    assert_equal 100, subtree.call(101)
  end

  # Value: protects=a location contains another in the same unit when its lines cover the other's, ends included, and two locations overlap when they share a line; fails_when=containment or overlap is strict at an end, or containment ignores which unit the lines are in; why_new=nothing tested Location's line arithmetic at its edges; seam=Location built directly
  # Contract: matcher/M4
  def test_locations_contain_and_overlap_inclusively_within_one_unit
    one, other = entries_for([method_source("A", calls(%w[alpha beta])), method_source("B", calls(%w[alpha beta]))])
    at = ->(entry, first, last) { Exhale::Dry::Location.new(entry: entry, start_line: first, end_line: last) }

    assert at.call(one, 3, 6).contains?(at.call(one, 3, 6))
    assert at.call(one, 3, 6).contains?(at.call(one, 4, 5))
    refute at.call(one, 3, 6).contains?(at.call(one, 2, 5))
    refute at.call(one, 3, 6).contains?(at.call(one, 4, 7))
    refute at.call(one, 3, 6).contains?(at.call(other, 3, 6))
    refute at.call(one, 3, 6).contains?(at.call(other, 4, 6))

    assert at.call(one, 3, 6).overlaps?(at.call(one, 6, 9))
    assert at.call(one, 6, 9).overlaps?(at.call(one, 3, 6))
    refute at.call(one, 3, 6).overlaps?(at.call(one, 7, 9))
    refute at.call(one, 3, 6).overlaps?(at.call(other, 3, 6))
  end

  # Value: protects=a fingerprint shared by more units weighs less, from counts taken over every entry; fails_when=the index weighs fingerprints without counting them; why_new=weights were only tested on the Weights table directly; seam=none
  # Contract: fingerprint/F2
  def test_the_index_weighs_a_common_fingerprint_below_a_rare_one
    entry = ->(id, set) { Exhale::Dry::Entry.new(id: id, set: Set.new(set)) }
    index = Exhale::Dry::Index.new([entry.call(0, [1, 2]), entry.call(1, [1, 3]), entry.call(2, [1, 4])])

    assert_equal 3, index.count(1)
    assert_equal 1, index.count(2)
    assert_operator index.weights[1], :<, index.weights[2]
  end

  # Value: protects=a run's number counts earlier copies in statement sequences only, so its key doesn't depend on matching argument lists; fails_when=an argument list holding the same calls counts as an earlier copy and the run's key changes; why_new=no test put a run's statements in an argument list before it; seam=none
  # Contract: matcher/M5
  def test_a_run_is_numbered_among_statement_sequences_only
    shared = %w[alpha beta gamma delta]
    combined = "combine(\n      #{calls(shared, ",\n      ")}\n    )"
    block = "items.each do |item|\n      #{calls(pad('a', 6) + shared + pad('c', 6), "\n      ")}\n    end"
    a = method_source("A", "#{combined}\n    #{block}")
    b = method_source("B", calls(pad("b", 6) + shared + pad("d", 6)))

    run = matches_for([a, b]).find { |m| m.kind == :run && m.a.path != m.b.path }

    assert_equal %w[1 1], [run.a, run.b].map { |l| l.key[/#(\d+)\z/, 1] }
  end

  # Value: protects=a copy squeezed onto too few lines never stands for its group, so the real unit's near copies are still found; fails_when=a unit clearing only one floor joins the matching, becomes its group's representative, and fails every pair it stands for; why_new=no test had a unit below one floor and above the other; seam=none
  # Contract: matcher/M1
  def test_a_squeezed_copy_does_not_hide_the_units_near_copies
    body = %w[alpha beta gamma delta]
    squeezed = method_source("Squeezed", calls(body, "; "))
    unit = method_source("Unit", calls(body))
    near = method_source("Near", calls(body + %w[epsilon]))

    pairs = matches_for([squeezed, unit, near]).select { |m| m.kind == :unit }.map { |m| [m.a, m.b].map { |l| l.unit.identity }.sort }

    assert_includes pairs, %w[Near#near Unit#unit]
  end

  # Value: protects=a fragment below the line floor is left out before groups are paired, so it can't head a star of more than 100 copies; fails_when=a squeezed copy joins the group, heads the star, and every pair it stands for fails the floors; why_new=no fragment group mixed a squeezed copy with full ones; seam=none
  # Contract: matcher/M7
  def test_a_squeezed_fragment_copy_does_not_head_a_large_group
    full = "if v.ok?\n      go(v, v.id)\n      stop(v, v.id)\n      log(v.id)\n    end"
    squeezed = "if v.ok? then go(v, v.id); stop(v, v.id); log(v.id) end"
    sources = (1..101).map do |n|
      steps = (1..6).map { |k| "step_#{n}_#{k}(v)" }.join("\n    ")
      "class M#{n}\n  def run(v)\n    #{steps}\n    #{n == 1 ? squeezed : full}\n  end\nend\n"
    end
    settings = { threshold: Rational(9, 10), min_lines: 4, min_nodes: 15 }

    assert_equal 100 * 99 / 2, matches_for(sources, settings).count { |m| m.kind == :subtree }
  end

  # Value: protects=within one method, a smaller run is dropped only when both its copies sit inside the two copies of a larger run; fails_when=one copy inside either side of the larger run is enough, so a third copy elsewhere in the method disappears; why_new=the pruning tests paired runs across two methods only; seam=none
  # Contract: matcher/M4
  def test_a_third_copy_of_part_of_a_repeated_run_in_one_method_stays
    long = %w[alpha beta gamma delta epsilon zeta]
    part = %w[beta gamma delta epsilon]
    source = method_source("A", calls(pad("a", 6) + long + pad("b", 6) + long + pad("c", 6) + part + pad("d", 6)))

    runs = matches_for([source]).select { |m| m.kind == :run }.map { |m| spans(m) }

    assert_includes runs, [[9, 14], [21, 26]]
    assert_includes runs, [[10, 13], [33, 36]]
    assert_includes runs, [[22, 25], [33, 36]]
  end

  private

  # Every pair of positions where three statements match, as run seeds are.
  def seeds(left, right)
    (0..left.size - 3).flat_map do |i|
      (0..right.size - 3).filter_map do |j|
        [i, j] if (0...3).all? { |k| left[i + k].digest == right[j + k].digest }
      end
    end
  end

  # Could a run end at p and q grow one more step in direction step: the
  # next statements match, or, with budget left, the ones after them do.
  def grows?(left, right, p, q, step, budget)
    inside = ->(x, y) { x >= 0 && y >= 0 && x < left.size && y < right.size }
    return false unless inside.call(p, q)
    return true if left[p].digest == right[q].digest

    budget.positive? && inside.call(p + step, q + step) && left[p + step].digest == right[q + step].digest
  end

  # Distinct statements, so padding never matches across the two methods
  # and the whole methods stay far below the threshold.
  def pad(tag, count)
    (1..count).map { |n| "pad_#{tag}#{n}" }
  end

  RUN_SETTINGS = { threshold: Rational(1, 2), min_lines: 4, min_nodes: 20 }.freeze

  # A method body of calls with the same arguments, one per line.
  def calls(names, joiner = "\n    ")
    names.map { |name| "#{name}(items, user.id)" }.join(joiner)
  end

  def method_source(klass, body)
    "class #{klass}\n  def #{klass.downcase}(items, user)\n    #{body}\n  end\nend\n"
  end

  def matches_for(sources, settings = RUN_SETTINGS)
    index = Exhale::Dry::Index.new(entries_for(sources))
    Exhale::Dry::Matcher.new(index, floors: settings, settings_for_pair: ->(_a, _b) { settings }).matches
  end

  def spans(match)
    [match.a, match.b].sort_by { |l| [l.path, l.start_line] }.map { |l| [l.start_line, l.end_line] }
  end

  # The line ranges of every run match between two methods made of the
  # given statement names, each one a call with the same arguments.
  def run_lines(left, right, settings = RUN_SETTINGS)
    sources = [method_source("A", calls(left)), method_source("B", calls(right))]
    matches_for(sources, settings).select { |m| m.kind == :run }.map { |m| spans(m) }
  end
end
