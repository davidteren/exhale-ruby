# frozen_string_literal: true

require "test_helper"
require "exhale/unit"
require "exhale/units/ruby"
require "exhale/dry/normalizer"
require "exhale/dry/fingerprints"
require "exhale/dry/index"
require "exhale/dry/matcher"
require "exhale/dry/check"
require "tmpdir"
require "fileutils"

# The matcher's obligations (contract/matcher/README.md), each driven through
# the public Matcher entry point on real Ruby source.
class MatcherContractTest < Minitest::Test
  SETTINGS = { threshold: Rational(4, 5), min_lines: 4, min_nodes: 20 }.freeze

  # A fragment big enough to stand alone: six lines, more than twenty nodes.
  FRAGMENT = <<~RUBY.gsub(/^/, "    ").chomp
    if order.paid?
      ledger.credit(order.total, order.currency)
      mailer.receipt(order).deliver_later
      audit.log(:paid, order.id)
      metrics.increment("orders.paid", tags: [order.region])
    end
  RUBY

  # Four statements, one per line, so no subtree inside them is big enough
  # to be a fragment: only the statement-run seeder can find this.
  RUN = [
    "subtotal = lines.sum { |l| l.amount * l.quantity }",
    "tax = subtotal * rate_for(region)",
    "discount = lines.select(&:discounted?).sum(&:discount)",
    "ledger.post(subtotal + tax - discount)"
  ].freeze

  def entries_for(sources)
    units = sources.each_with_index.flat_map { |source, i| Exhale::Units::Ruby.extract(source, "app/models/m#{i}.rb") }
    units.each_with_index.map do |unit, id|
      tree = Exhale::Dry::Fingerprints.build(Exhale::Dry::Normalizer.normalize(unit))
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
    end
  end

  def matches_for(sources, settings: SETTINGS)
    index = Exhale::Dry::Index.new(entries_for(sources))
    Exhale::Dry::Matcher.new(index, floors: settings, settings_for_pair: ->(_a, _b) { settings }).matches
  end

  # A method whose every other statement calls something no other method
  # calls, so no two of these methods are similar as wholes.
  def method_source(i, body)
    "class M#{i}\n  def run#{i}(lines, order)\n    prepare_#{i}!(lines)\n    audit_#{i}(lines.size)\n" \
      "#{body}\n    archive_#{i}!(order)\n    notify_#{i}(order)\n  end\nend\n"
  end

  def run_body
    RUN.map { |statement| "    #{statement}" }.join("\n")
  end

  def components(edges)
    parent = {}
    find = ->(x) { parent[x] ||= x; parent[x] == x ? x : (parent[x] = find.(parent[x])) }
    edges.each { |a, b| parent[find.(a)] = find.(b) }
    parent.keys.to_h { |x| [x, find.(x)] }
  end

  def assert_one_group_over(copies, found)
    assert_equal copies, found.flat_map { |m| [m.a.entry.id, m.b.entry.id] }.uniq.size
    groups = components(found.map { |m| [m.a.id, m.b.id] })
    assert_equal copies, groups.size
    assert_equal 1, groups.values.uniq.size
  end

  # At 7622907 a run seeded in more than 50 places was skipped outright, so
  # a run pasted into 51 methods passed the gate.
  # Contract: matcher/M3
  def test_a_statement_run_copied_into_51_methods_is_found_as_one_group
    found = matches_for((0...51).map { |i| method_source(i, run_body) })

    runs = found.select { |m| m.kind == :run }
    refute_empty runs
    assert_equal found, runs
    assert_one_group_over 51, runs
  end

  # Contract: matcher/M3
  def test_a_statement_run_copied_into_120_methods_is_found_as_one_group
    runs = matches_for((0...120).map { |i| method_source(i, run_body) }).select { |m| m.kind == :run }

    refute_empty runs
    assert_one_group_over 120, runs
  end

  # Contract: matcher/M3
  def test_a_run_survives_one_mismatched_statement
    original = RUN + ["flush!"] + ["mailer.receipt(order).deliver_later", "audit.log(:settled, order.id)",
                                   "metrics.increment(\"orders.settled\")"]
    edited = original.dup
    edited[4] = "reset!"
    sources = [original, edited].each_with_index.map do |body, i|
      method_source(i, body.map { |statement| "    #{statement}" }.join("\n"))
    end

    found = matches_for(sources)

    assert_equal [:run], found.map(&:kind)
    assert_equal [5, 12], [found[0].a.start_line, found[0].a.end_line]
    assert_equal [5, 12], [found[0].b.start_line, found[0].b.end_line]
  end

  # Past STAR_ABOVE copies the group is connected as a star from its first
  # copy instead of pairwise; every copy must still be in the one group.
  # Contract: matcher/M2
  def test_a_fragment_copied_into_more_than_star_above_places_is_one_group
    copies = Exhale::Dry::Matcher::STAR_ABOVE + 5
    found = matches_for((0...copies).map { |i| method_source(i, FRAGMENT) })

    subtrees = found.select { |m| m.kind == :subtree }
    assert_equal found, subtrees
    assert_one_group_over copies, subtrees
    assert(subtrees.all? { |m| m.a.lines == 6 && m.b.lines == 6 })
  end

  # Contract: matcher/M2
  def test_a_fragment_copied_into_a_few_places_is_found_pairwise
    found = matches_for((0...3).map { |i| method_source(i, FRAGMENT) }).select { |m| m.kind == :subtree }

    assert_equal 3, found.size
    assert_one_group_over 3, found
  end

  # At 7622907 a fragment's key was unit identity plus structure, so the
  # second copy of a fragment in one method had the first copy's key and a
  # new copy could pass for an old one.
  # Contract: matcher/M5
  def test_two_copies_of_a_fragment_in_one_method_have_different_keys
    source = "class A\n  def settle(order)\n#{FRAGMENT}\n    prepare!(order)\n#{FRAGMENT}\n  end\nend\n"

    found = matches_for([source]).select { |m| m.kind == :subtree }

    assert_equal 1, found.size
    a, b = found[0].a, found[0].b
    assert_equal a.unit.identity, b.unit.identity
    assert_equal a.structural_key, b.structural_key
    refute_equal a.key, b.key
    # Copies are numbered in preorder from 1, and the number ends the key.
    assert_equal %w[1 2], [a, b].sort_by(&:start_line).map { |l| l.key[/#(\d+)\z/, 1] }
  end

  # Contract: matcher/M5
  def test_two_copies_of_a_statement_run_in_one_method_have_different_keys
    source = "class A\n  def settle(lines, order)\n#{run_body}\n    prepare!(order)\n#{run_body}\n  end\nend\n"

    found = matches_for([source]).select { |m| m.kind == :run }

    assert_equal 1, found.size
    a, b = found[0].a, found[0].b
    assert_equal a.unit.identity, b.unit.identity
    refute_equal a.key, b.key
    # The earlier copy is the first: numbering follows the method's statements.
    assert_equal %w[1 2], [a, b].sort_by(&:start_line).map { |l| l.key[/#(\d+)\z/, 1] }
  end

  # Contract: matcher/M4
  def test_a_fragment_inside_a_unit_match_between_the_same_two_units_is_dropped
    near = method_source(0, "#{FRAGMENT}\n#{run_body}")
    edited = near.sub("class M0", "class M1").sub("notify_0(order)", "notify_0!(order)")
    other = method_source(2, FRAGMENT)

    found = matches_for([near, edited, other])

    between = found.select { |m| [m.a.entry.id, m.b.entry.id].sort == [0, 1] }
    assert_equal [:unit], between.map(&:kind)
    assert_operator between[0].score, :<, 1
    # The same fragment against a unit with no bigger match stays.
    assert(found.any? { |m| m.kind == :subtree && [m.a.entry.id, m.b.entry.id].sort == [0, 2] })
    assert(found.any? { |m| m.kind == :subtree && [m.a.entry.id, m.b.entry.id].sort == [1, 2] })
  end

  # Identical units join their group as a star, so two of them may have no
  # unit match between them; the fragments they share still say nothing new.
  # Contract: matcher/M4
  def test_fragments_between_identical_units_are_not_reported_separately
    twin = method_source(0, FRAGMENT)
    twins = (0...3).map { |i| twin.sub("class M0", "class T#{i}") }
    other = method_source(9, FRAGMENT)

    found = matches_for(twins + [other])

    among_twins = found.reject { |m| m.a.whole }.select { |m| [m.a.entry.id, m.b.entry.id].all? { |id| id < 3 } }
    assert_empty among_twins
    assert_equal 2, found.count { |m| m.kind == :unit }
    assert(found.any? { |m| m.kind == :subtree && [m.a.entry.id, m.b.entry.id].include?(3) })
  end

  # At 7622907, 800 identical scaffold actions made 320,000 pairs.
  # Contract: matcher/M7
  def test_identical_units_cost_close_to_linear
    body = "    authorize! :read, record\n    respond_to do |format|\n      format.html { render :show }\n" \
           "      format.json { render json: record.as_json(only: %i[id name]) }\n    end"
    sources = (0...800).map { |i| "class C#{i}\n  def show(record)\n#{body}\n  end\nend\n" }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    found = matches_for(sources)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator found.size, :<, 2 * 800
    assert_one_group_over 800, found
    assert_operator elapsed, :<, 5.0
  end

  BODY = ["total = items.sum { |i| i.amount }", "tax = total * rate_for(region)", "notify(user, total)",
          "log.info(total.to_s)", "cache.write(key, total)", "audit!(user, :checked)", "mailer.deliver_later(user)"].freeze

  def write_tree(root, files)
    files.each do |path, content|
      full = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
    end
  end

  def namespaced(namespace, klass, body)
    "module #{namespace}\n  class #{klass}\n    def run(items, user)\n" \
      "#{body.map { |statement| "      #{statement}" }.join("\n")}\n    end\n  end\nend\n"
  end

  # "Stricter" is the side that flags more: the lower threshold and the
  # lower size floors. Billing only flags near-exact copies; Ledger flags
  # anything over a half. A pair across the two is judged by Ledger's.
  # Contract: matcher/M6
  def test_a_pair_across_two_primitives_is_judged_by_the_stricter_settings
    Dir.mktmpdir("exhale-m6") do |root|
      one_off = BODY.dup.tap { |b| b[3] = "items.each { |i| i.touch }" }
      other_off = BODY.dup.tap { |b| b[3] = "raise Error unless valid?" }
      write_tree(root, {
        "contract/billing/README.md" => "# Billing\n\n```covers\nBilling\n```\n",
        "contract/billing/duplication.md" => "```settings\nthreshold: 0.95\nmin-lines: 30\n```\n",
        "contract/ledger/README.md" => "# Ledger\n\n```covers\nLedger\n```\n",
        "contract/ledger/duplication.md" => "```settings\nthreshold: 0.5\nmin-lines: 4\n```\n",
        "app/models/billing/invoice.rb" => namespaced("Billing", "Invoice", BODY),
        "app/models/billing/quote.rb" => namespaced("Billing", "Quote", one_off),
        "app/models/ledger/entry.rb" => namespaced("Ledger", "Entry", other_off)
      })

      sweep = Exhale::Dry::Sweep.new(root).run
      units = sweep.units.to_h { |unit| [unit.identity, unit] }
      pairs = sweep.matches.select { |m| m.kind == :unit }.map { |m| [m.a.unit.identity, m.b.unit.identity].sort }
      entry = ->(identity) { sweep.index.entries.find { |e| e.unit.identity == identity } }
      score = ->(a, b) { sweep.index.score(entry.(a).set, entry.(a).total, entry.(b).set, entry.(b).total) }

      assert_empty sweep.contract.errors
      across = sweep.settings_for_pair(units["Billing::Invoice#run"], units["Ledger::Entry#run"])
      assert_equal Rational(1, 2), across[:threshold]
      assert_equal 4, across[:min_lines]
      assert_operator score.("Billing::Invoice#run", "Billing::Quote#run"), :<, Rational(95, 100)
      assert_operator score.("Billing::Invoice#run", "Billing::Quote#run"), :>=, Rational(1, 2)
      assert_operator score.("Billing::Invoice#run", "Ledger::Entry#run"), :<, Rational(95, 100)
      assert_includes pairs, ["Billing::Invoice#run", "Ledger::Entry#run"]
      assert_includes pairs, ["Billing::Quote#run", "Ledger::Entry#run"]
      refute_includes pairs, ["Billing::Invoice#run", "Billing::Quote#run"]
    end
  end

  # Billing's own floors are out of reach for its identical copies, so the
  # copies don't join each other, but Ledger's lower floors apply to the
  # pair across the two. Each copy is reported against the near copy,
  # whichever side of the pair its identical siblings sit on.
  # Contract: matcher/M1
  def test_identical_units_that_miss_their_own_floors_each_pair_with_a_near_copy
    strict = { threshold: Rational(19, 20), min_lines: 30, min_nodes: 20 }
    lenient = { threshold: Rational(1, 2), min_lines: 4, min_nodes: 20 }
    near = BODY.dup.tap { |body| body[3] = "raise Error unless valid?" }
    method = ->(name, body) { "class #{name}\n  def run(items, user)\n#{body.map { |s| "    #{s}" }.join("\n")}\n  end\nend\n" }
    settings_for_pair = ->(a, b) { a.identity.start_with?("Billing") && b.identity.start_with?("Billing") ? strict : lenient }

    [%w[Billing1 Billing2 Billing3 Ledger], %w[Ledger Billing1 Billing2 Billing3]].each do |order|
      sources = order.map { |name| method.call(name, name.start_with?("Ledger") ? near : BODY) }
      index = Exhale::Dry::Index.new(entries_for(sources))
      found = Exhale::Dry::Matcher.new(index, floors: lenient, settings_for_pair: settings_for_pair).matches
      pairs = found.select { |m| m.kind == :unit }.map { |m| [m.a.unit.identity, m.b.unit.identity].sort }

      expected = %w[Billing1 Billing2 Billing3].map { |name| ["#{name}#run", "Ledger#run"].sort }

      assert_equal expected.sort, pairs.sort, order.inspect
    end
  end

  # Two identical units on one line can't pair with each other, so each one
  # pairs with the copy elsewhere instead of with its neighbor.
  # Contract: matcher/M8
  def test_identical_units_sharing_a_line_each_pair_with_a_copy_elsewhere
    floors = { threshold: Rational(1, 2), min_lines: 1, min_nodes: 5 }
    body = "total = items.sum { |i| i.amount }; tax = total * 2;"
    crowded = "class A\n  def first(items) #{body} end; def second(items) #{body} end\nend\n"
    apart = "class B\n  def third(items)\n    #{body.sub('; ', "\n    ")}\n  end\nend\n"

    index = Exhale::Dry::Index.new(entries_for([crowded, apart]))
    found = Exhale::Dry::Matcher.new(index, floors: floors, settings_for_pair: ->(_a, _b) { floors }).matches

    assert_equal [%w[A#first B#third], %w[A#second B#third]],
                 found.select { |m| m.kind == :unit }.map { |m| [m.a.unit.identity, m.b.unit.identity].sort }.sort
  end

  def kinds_and_starts(found)
    found.map { |m| [m.kind, m.a.start_line, m.b.start_line] }.sort
  end

  def tree_of(source)
    entries_for([source]).first.tree
  end

  # FRAGMENT squeezed onto one line: the same tree on fewer lines.
  COMPACT = "    if order.paid? then ledger.credit(order.total, order.currency); " \
            "mailer.receipt(order).deliver_later; audit.log(:paid, order.id); " \
            "metrics.increment(\"orders.paid\", tags: [order.region]) end"

  # A method made of one statement per name, each a distinct call.
  def calls_method(name, calls)
    "class #{name}\n  def run(order)\n#{calls.map { |c| "    #{c}(order.id, order.total)" }.join("\n")}\n  end\nend\n"
  end

  # One unit holds a lone copy F1 of a fragment, then two copies of a bigger
  # fragment H that each hold a copy of F. H1~H2 is the larger match, and
  # F2~F3 lie inside its two sides, so only that pair is dropped: F1 sits
  # outside both H copies, so F1~F2 and F1~F3 each have a side outside it.
  # Contract: matcher/M4
  def test_only_a_match_inside_both_sides_of_a_larger_match_is_dropped
    nested = FRAGMENT.gsub(/^/, "  ")
    source = "class A\n  def settle(order)\n#{FRAGMENT}\n" \
             "    if order.open?\n#{nested}\n      reconcile(order)\n    end\n" \
             "    if order.open?\n#{nested}\n      reconcile(order)\n    end\n  end\nend\n"

    found = matches_for([source])

    assert_equal [[:subtree, 3, 10], [:subtree, 3, 19], [:subtree, 9, 18]], kinds_and_starts(found)
  end

  # Containment includes a shared first or last line: a fragment that
  # starts or ends a larger run between the same two units lies inside it.
  # Contract: matcher/M4
  def test_a_fragment_that_starts_or_ends_a_larger_run_is_dropped
    starts = "#{FRAGMENT}\n    #{RUN[0]}\n    #{RUN[1]}"
    ends = "    #{RUN[0]}\n    #{RUN[1]}\n#{FRAGMENT}"

    [starts, ends].each do |body|
      found = matches_for([method_source(0, body), method_source(1, body)])

      assert_equal [[:run, 5, 5]], kinds_and_starts(found), body
      assert_equal 12, found[0].a.end_line
    end
  end

  def disjoint?(match)
    match.a.end_line < match.b.start_line || match.b.end_line < match.a.start_line
  end

  # Two copies that share a line are never paired: the second copy of a
  # fragment opening on the line the first one closes, and a run repeated
  # on one line under floors that would otherwise take it.
  # Contract: matcher/M8
  def test_copies_that_share_a_line_are_never_paired
    joined = "#{FRAGMENT}; #{FRAGMENT.lstrip}"
    found = matches_for(["class A\n  def settle(order)\n#{joined}\n  end\nend\n"])

    # The copies are lines 3-8 and 8-13; their bodies, which share no line,
    # may still pair.
    refute(found.any? { |m| [m.a.start_line, m.b.start_line] == [3, 8] })
    refute_empty found
    assert(found.all? { |m| disjoint?(m) })

    one_line = "class A\n  def run(items)\n    a(items); b(items); c(items); a(items); b(items); c(items)\n  end\nend\n"
    assert_empty matches_for([one_line], settings: { threshold: Rational(4, 5), min_lines: 1, min_nodes: 4 })
  end

  # Contract: matcher/M1
  def test_a_unit_exactly_at_the_floors_is_compared
    source = method_source(0, FRAGMENT)
    twin = source.sub("class M0", "class N0")
    entry = entries_for([source]).first
    at = { threshold: Rational(4, 5), min_lines: entry.unit.lines, min_nodes: entry.tree.size }

    found = matches_for([source, twin], settings: at)

    assert_equal [:unit], found.map(&:kind)
  end

  # A copy of a unit squeezed below the floors isn't compared, so it can't
  # stand in for its identical group: the two full copies still match.
  # Contract: matcher/M1
  def test_a_copy_below_the_floors_does_not_stand_for_its_identical_group
    compact = "class A\n  def run1(lines, order)\n    prepare!(lines); #{COMPACT.strip}; archive!(order)\n  end\nend\n"
    full = "class B\n  def run1(lines, order)\n    prepare!(lines)\n#{FRAGMENT}\n    archive!(order)\n  end\nend\n"
    assert_equal tree_of(compact).digest, tree_of(full).digest

    found = matches_for([compact, full, full.sub("class B", "class C")])

    assert_equal [[:unit, 2, 2]], kinds_and_starts(found)
    assert_equal [1, 2], [found[0].a.entry.id, found[0].b.entry.id]
  end

  def nodes_of(tree)
    tree.each_node.to_a
  end

  # A unit whose fingerprint set lies inside another's, its total exactly
  # the threshold times the other's, scores exactly the threshold and is
  # matched. Built from shapes so the totals are exact.
  # Contract: matcher/M1
  def test_a_pair_scoring_exactly_the_threshold_through_a_subset_is_matched
    leaf = ->(kind, label, line) { Exhale::Shape.new(kind: kind, label: label, children: [], start_line: line, end_line: line, sequence: false) }
    inner = Exhale::Shape.new(kind: "def_node", label: nil, start_line: 1, end_line: 3, sequence: false,
                              children: [leaf.("call_node", "charge", 2), leaf.("call_node", "refund", 3)])
    outer = Exhale::Shape.new(kind: "statements_node", label: nil, start_line: 1, end_line: 5, sequence: true,
                              children: [inner, leaf.("call_node", "void", 4), leaf.("call_node", "settle", 5)])
    entries = [[inner, 3], [outer, 5]].each_with_index.map do |(shape, lines), id|
      unit = Exhale::Unit.new(kind: :method, identity: "U#{id}#run", path: "u#{id}.rb", start_line: 1, end_line: lines,
                              language: :ruby)
      tree = Exhale::Dry::Fingerprints.build(shape)
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
    end
    index = Exhale::Dry::Index.new(entries)
    threshold = Rational(entries[0].total, entries[1].total)
    at = { threshold: threshold, min_lines: 1, min_nodes: 1 }

    found = Exhale::Dry::Matcher.new(index, floors: at, settings_for_pair: ->(*) { at }).matches

    assert entries[0].set.subset?(entries[1].set)
    assert_equal threshold, index.score(entries[0].set, entries[0].total, entries[1].set, entries[1].total)
    assert_equal [[0, 1, threshold]], found.select { |m| m.kind == :unit }.map { |m| [m.a.entry.id, m.b.entry.id, m.score] }
  end

  # Contract: matcher/M2
  def test_a_fragment_exactly_at_the_floors_is_found
    sources = [method_source(0, FRAGMENT), method_source(1, FRAGMENT)]
    fragment = nodes_of(entries_for(sources).first.tree).find { |node| node.start_line == 5 && node.end_line == 10 }
    at = { threshold: Rational(4, 5), min_lines: fragment.lines, min_nodes: fragment.size }

    found = matches_for(sources, settings: at)

    assert_equal [[:subtree, 5, 5]], kinds_and_starts(found)
  end

  # Past STAR_ABOVE copies the group is a star from its first copy. A first
  # copy squeezed below the floors isn't a candidate, so it can't be the
  # center that every pair fails against.
  # Contract: matcher/M2
  def test_a_copy_below_the_floors_does_not_center_a_big_group
    copies = Exhale::Dry::Matcher::STAR_ABOVE + 1
    compact = method_source(0, COMPACT)
    assert_equal tree_of(method_source(0, FRAGMENT)).digest, tree_of(compact).digest

    found = matches_for([compact] + (1..copies).map { |i| method_source(i, FRAGMENT) }).select { |m| m.kind == :subtree }

    refute(found.any? { |m| [m.a.entry.id, m.b.entry.id].include?(0) })
    assert_one_group_over copies, found
  end

  # Up to STAR_ABOVE copies every pair is listed; past it, a star.
  # Contract: matcher/M2
  def test_a_fragment_copied_star_above_times_is_listed_pairwise
    copies = Exhale::Dry::Matcher::STAR_ABOVE
    found = matches_for((0...copies).map { |i| method_source(i, FRAGMENT) }).select { |m| m.kind == :subtree }

    assert_equal copies * (copies - 1) / 2, found.size
  end

  # A unit is matched as a whole by the unit matcher; a fragment is a proper
  # part of a unit. A unit whose whole tree sits inside a bigger one is
  # found through its body, never as a fragment spanning the unit itself.
  # Contract: matcher/M2
  def test_a_unit_is_never_a_fragment_of_itself
    leaf = ->(kind, label, line) { Exhale::Shape.new(kind: kind, label: label, children: [], start_line: line, end_line: line, sequence: false) }
    body = lambda do |line|
      Exhale::Shape.new(kind: "statements_node", label: nil, start_line: line, end_line: line + 3, sequence: true,
                        children: %w[x y z w].each_with_index.map { |name, k| leaf.("call_node", name, line + k) })
    end
    method = ->(line) { Exhale::Shape.new(kind: "def_node", label: nil, start_line: line, end_line: line + 5, sequence: false, children: [body.(line + 1)]) }
    host = Exhale::Shape.new(kind: "def_node", label: nil, start_line: 1, end_line: 12, sequence: false, children: [
      Exhale::Shape.new(kind: "statements_node", label: nil, start_line: 2, end_line: 11, sequence: true,
                        children: [leaf.("call_node", "u1", 2), leaf.("call_node", "u2", 3), method.(4),
                                   leaf.("call_node", "u3", 10), leaf.("call_node", "u4", 11)])
    ])
    entries = [[method.(1), 6], [host, 12]].each_with_index.map do |(shape, lines), id|
      unit = Exhale::Unit.new(kind: :method, identity: "U#{id}#run", path: "u#{id}.rb", start_line: 1, end_line: lines,
                              language: :ruby)
      tree = Exhale::Dry::Fingerprints.build(shape)
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
    end
    settings = { threshold: Rational(4, 5), min_lines: 4, min_nodes: 5 }

    found = Exhale::Dry::Matcher.new(Exhale::Dry::Index.new(entries), floors: settings, settings_for_pair: ->(*) { settings }).matches

    assert_equal [[:subtree, 2, 5]], kinds_and_starts(found)
    assert_equal [2, 5], [found[0].a.start_line, found[0].a.end_line]
  end

  # Array elements on their own lines aren't statements, so a run of them
  # isn't a statement run.
  # Contract: matcher/M3
  def test_a_run_of_array_elements_is_not_a_statement_run
    rows = ->(names) { "    rows = [\n#{names.map { |n| "      fetch_#{n}(row, :a, 1)" }.join(",\n")}\n    ]" }
    a = method_source(0, rows.(%w[alpha beta gamma delta epsilon]))
    b = method_source(1, rows.(%w[alpha beta gamma delta epsilon zeta]))

    assert_empty matches_for([a, b])
  end

  # A sequence of exactly three statements is a run's whole: here a method
  # body of three statements, copied into the middle of a longer one.
  # Contract: matcher/M3
  def test_a_whole_sequence_of_exactly_three_statements_is_a_run
    three = "    #{RUN[0]}\n    #{RUN[1]}\n    ledger.post(\n      subtotal + tax\n    )"
    a = "class A\n  def settle(lines)\n#{three}\n  end\nend\n"
    b = method_source(1, three)

    found = matches_for([a, b])

    assert_equal [[:run, 3, 5]], kinds_and_starts(found)
    assert_equal [3, 7], [found[0].a.start_line, found[0].a.end_line]
  end

  # Two copies of a run back to back in one sequence are found.
  # Contract: matcher/M3
  def test_a_run_copied_right_after_itself_is_found
    source = "class A\n  def settle(lines, order)\n#{run_body}\n#{run_body}\n  end\nend\n"

    found = matches_for([source])

    assert_equal [[:run, 3, 7]], kinds_and_starts(found)
  end

  # Contract: matcher/M5
  def test_two_copies_of_a_run_neither_opening_its_method_have_different_keys
    source = "class A\n  def settle(lines, order)\n    prepare!(order)\n#{run_body}\n    review!(order)\n#{run_body}\n  end\nend\n"

    found = matches_for([source]).select { |m| m.kind == :run }

    assert_equal 1, found.size
    assert_equal %w[1 2], [found[0].a, found[0].b].sort_by(&:start_line).map { |l| l.key[/#(\d+)\z/, 1] }
  end

  # A run's key counts earlier copies among statements only, so the same
  # calls appearing as arguments earlier in the unit don't renumber it. The
  # run sits in a block so the lookalike comes first in preorder.
  # Contract: matcher/M5
  def test_a_run_key_ignores_lookalikes_that_are_not_statements
    steps = %w[step_one step_two step_three step_four]
    call = ->(name) { "#{name}(order.id, order.total)" }
    locked = "class A\n  def run(order)\n    order.with_lock do\n" \
             "#{steps.map { |s| "      #{call.(s)}" }.join("\n")}\n    end\n  end\nend\n"
    traced = locked.sub("  def run(order)\n", "  def run(order)\n    trace(#{steps.map(&call).join(', ')})\n")
    other = calls_method("B", %w[warm_up] + steps + %w[cool_down])

    keys = [locked, traced].map do |source|
      run = matches_for([source, other]).find { |m| m.kind == :run }
      [run.a, run.b].find { |l| l.unit.identity == "A#run" }.key
    end

    assert_equal 1, keys.uniq.size
    assert_match(/#1\z/, keys[0])
  end

  # A copy squeezed below the floors isn't a candidate, so it doesn't count
  # toward STAR_ABOVE: a hundred real copies are still listed pairwise.
  # Contract: matcher/M2
  def test_a_copy_below_the_floors_does_not_count_toward_star_above
    copies = Exhale::Dry::Matcher::STAR_ABOVE
    sources = [method_source(0, COMPACT)] + (1..copies).map { |i| method_source(i, FRAGMENT) }

    found = matches_for(sources).select { |m| m.kind == :subtree }

    assert_equal copies * (copies - 1) / 2, found.size
    refute(found.any? { |m| [m.a.entry.id, m.b.entry.id].include?(0) })
  end

  # The settings a pair is judged by bind both of its sides. Floors let a
  # six-line copy in as a candidate, but its pair asks for ten lines.
  # Contract: matcher/M6
  def test_both_sides_of_a_pair_must_meet_its_settings
    spread = "class A\n  def show(record)\n    authorize!(\n      :read,\n      record\n    )\n" \
             "    respond_to do |format|\n      format.html { render :show }\n      format.json do\n" \
             "        render json: record.as_json(only: %i[id name])\n      end\n    end\n  end\nend\n"
    short = "class B\n  def show(record)\n    authorize!(:read, record)\n    respond_to do |format|\n" \
            "      format.html { render :show }; format.json do render json: record.as_json(only: %i[id name]) end\n" \
            "    end\n  end\nend\n"
    sources = [spread, short, spread.sub("class A", "class C")]
    assert_equal 1, entries_for(sources).map { |e| e.tree.digest }.uniq.size
    floors = { threshold: Rational(4, 5), min_lines: 4, min_nodes: 20 }
    pair = floors.merge(min_lines: 10)
    index = Exhale::Dry::Index.new(entries_for(sources))

    found = Exhale::Dry::Matcher.new(index, floors: floors, settings_for_pair: ->(*) { pair }).matches

    assert_equal [[0, 2]], found.map { |m| [m.a.entry.id, m.b.entry.id] }
  end

  # Size floors per unit, as the Contract gives them, and a pair judged by
  # the lower of its two sides' floors.
  def floors_by_namespace(table)
    own = ->(unit) { table.fetch(unit.identity[/\A\w+/]) }
    lambda do |a, b|
      x = own.(a)
      y = own.(b)
      x.merge(y) { |_key, p, q| [p, q].min }
    end
  end

  # Three identical units. Lenient asks for thirty lines, Strict for four,
  # so Lenient::X~Lenient::Y fails while either one with Strict::Z passes.
  # A star centered on X would leave Y out of every match.
  # Contract: matcher/M1
  # Contract: matcher/M6
  def test_a_star_of_identical_units_reaches_every_copy_a_pair_would
    body = "    authorize! :read, record\n    respond_to do |format|\n      format.html { render :show }\n" \
           "      format.json { render json: record.as_json(only: %i[id name]) }\n    end\n    audit(record)\n" \
           "    notify(record)\n    log(record)"
    sources = %w[Lenient::X Lenient::Y Strict::Z].map do |name|
      mod, klass = name.split("::")
      "module #{mod}\n  class #{klass}\n    def show(record)\n#{body}\n    end\n  end\nend\n"
    end
    base = { threshold: Rational(4, 5), min_nodes: 20 }
    per_pair = floors_by_namespace("Lenient" => base.merge(min_lines: 30), "Strict" => base.merge(min_lines: 4))
    index = Exhale::Dry::Index.new(entries_for(sources))

    found = Exhale::Dry::Matcher.new(index, floors: base.merge(min_lines: 4), settings_for_pair: per_pair).matches

    units = found.select { |m| m.kind == :unit }
    assert_one_group_over 3, units
  end

  # Past STAR_ABOVE copies a fragment group is a star. The first copy here
  # is in a primitive asking for thirty lines and is written on five, so it
  # fails against every partner; the hundred others, on six lines under a
  # six-line floor, still pass with each other and must stay one group.
  # Contract: matcher/M2
  # Contract: matcher/M6
  def test_a_big_fragment_group_is_centered_on_a_copy_that_can_pass
    tight = FRAGMENT.sub("deliver_later\n      audit", "deliver_later; audit")
    copies = Exhale::Dry::Matcher::STAR_ABOVE + 1
    sources = ["module Lenient\n#{method_source(0, tight)}end\n"] +
              (1..copies).map { |i| "module Medium\n#{method_source(i, FRAGMENT)}end\n" }
    digest_at = ->(entry, first, last) { entry.tree.each_node.find { |n| n.start_line == first && n.end_line == last }.digest }
    squeezed, spread = entries_for(sources.first(2))
    assert_equal digest_at.(spread, 6, 11), digest_at.(squeezed, 6, 10)
    base = { threshold: Rational(4, 5), min_nodes: 20 }
    per_pair = floors_by_namespace("Lenient" => base.merge(min_lines: 30), "Medium" => base.merge(min_lines: 6))
    index = Exhale::Dry::Index.new(entries_for(sources))

    found = Exhale::Dry::Matcher.new(index, floors: base.merge(min_lines: 4), settings_for_pair: per_pair).matches
             .select { |m| m.kind == :subtree }

    refute(found.any? { |m| [m.a.entry.id, m.b.entry.id].include?(0) })
    assert_one_group_over copies, found
  end

  # Past RUN_SEED_CAP a run's seeds are a star. The first method has the
  # run squeezed onto one line, below twenty other lines, so a star from its
  # seed, the first and the lowest in its file, would fail the line floor
  # against all fifty-one real copies.
  # Contract: matcher/M3
  def test_a_big_run_group_is_centered_on_a_copy_that_can_pass
    copies = Exhale::Dry::Matcher::RUN_SEED_CAP + 1
    padding = (1..20).map { |k| "    step_#{k}(lines)\n" }.join
    sources = [method_source(0, "#{padding}    #{RUN.join('; ')}")] + (1..copies).map { |i| method_source(i, run_body) }

    runs = matches_for(sources).select { |m| m.kind == :run }

    refute(runs.any? { |m| [m.a.entry.id, m.b.entry.id].include?(0) })
    assert_one_group_over copies, runs
  end

  # A unit squeezed below the floors isn't a candidate, so its copy of a run
  # doesn't count toward RUN_SEED_CAP: fifty real copies are still listed
  # pairwise.
  # Contract: matcher/M3
  def test_a_unit_below_the_floors_does_not_count_toward_the_run_seed_cap
    copies = Exhale::Dry::Matcher::RUN_SEED_CAP
    squeezed = "class A\n  def run0(lines)\n    #{RUN.join('; ')}\n  end\nend\n"
    sources = [squeezed] + (1..copies).map { |i| method_source(i, run_body) }
    assert_operator entries_for([squeezed]).first.unit.lines, :<, SETTINGS[:min_lines]

    runs = matches_for(sources).select { |m| m.kind == :run }

    assert_equal copies * (copies - 1) / 2, runs.size
  end

  def matcher_with(sources, floors, per_pair)
    Exhale::Dry::Matcher.new(Exhale::Dry::Index.new(entries_for(sources)), floors: floors, settings_for_pair: per_pair)
  end

  def connected?(found, id_a, id_b)
    groups = components(found.map { |m| [m.a.entry.id, m.b.entry.id] })
    groups.key?(id_a) && groups[id_a] == groups[id_b]
  end

  # A and B are identical; A's primitive only flags near-exact copies, B's
  # anything over a half. C is a near copy of both, judged with Exact's
  # threshold against A and Loose's against B. One hub for {A, B} in the
  # search for near copies would compare C with A only and miss B~C.
  # Contract: matcher/M1
  # Contract: matcher/M6
  def test_a_near_copy_is_compared_with_each_settings_class_of_an_identical_group
    edited = BODY.dup.tap { |b| b[3] = "items.each { |i| i.touch }" }
    sources = [namespaced("Exact", "A", BODY), namespaced("Loose", "B", BODY), namespaced("Exact", "C", edited)]
    base = { min_lines: 4, min_nodes: 20 }
    per_pair = floors_by_namespace("Exact" => base.merge(threshold: Rational(99, 100)),
                                   "Loose" => base.merge(threshold: Rational(1, 2)))
    matcher = matcher_with(sources, base.merge(threshold: Rational(1, 2)), per_pair)
    index = matcher.instance_variable_get(:@index)
    b, c = index.entries[1], index.entries[2]
    score = index.score(b.set, b.total, c.set, c.total)

    found = matcher.matches

    assert_operator score, :>=, Rational(1, 2)
    assert_operator score, :<, Rational(99, 100)
    units = found.select { |m| m.kind == :unit }
    assert connected?(units, 1, 2), units.map { |m| [m.a.entry.id, m.b.entry.id] }.inspect
  end

  # Floors are two-dimensional. Identical 44-node units on 4, 5 and 15
  # lines ask for (4 lines, 100 nodes), (10, 20) and (15, 20). A~B is judged
  # at (4, 20) and qualifies, A~C at (4, 20) qualifies, B~C at (10, 20)
  # doesn't. A star from C, the only copy meeting its own floors, leaves B
  # out; every qualifying pair must still be connected.
  # Contract: matcher/M1
  # Contract: matcher/M6
  def test_identical_units_with_two_dimensional_floors_connect_every_qualifying_pair
    leaf = ->(name) { Exhale::Shape.new(kind: "call_node", label: name, children: [], start_line: 1, end_line: 1, sequence: false) }
    body = Exhale::Shape.new(kind: "statements_node", label: nil, children: (1..42).map { |k| leaf.("s#{k}") },
                             start_line: 1, end_line: 1, sequence: true)
    shape = Exhale::Shape.new(kind: "def_node", label: nil, children: [body], start_line: 1, end_line: 1, sequence: false)
    own = { "A" => { min_lines: 4, min_nodes: 100 }, "B" => { min_lines: 10, min_nodes: 20 }, "C" => { min_lines: 15, min_nodes: 20 } }
    entries = [["A", 4], ["B", 5], ["C", 15]].each_with_index.map do |(name, lines), id|
      unit = Exhale::Unit.new(kind: :method, identity: "#{name}#run", path: "#{name.downcase}.rb", start_line: 1,
                              end_line: lines, language: :ruby)
      tree = Exhale::Dry::Fingerprints.build(shape)
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
    end
    per_pair = lambda do |a, b|
      x = own.fetch(a.identity[0])
      y = own.fetch(b.identity[0])
      x.merge(y) { |_key, p, q| [p, q].min }.merge(threshold: Rational(4, 5))
    end
    floors = { threshold: Rational(4, 5), min_lines: 4, min_nodes: 20 }

    found = Exhale::Dry::Matcher.new(Exhale::Dry::Index.new(entries), floors: floors, settings_for_pair: per_pair).matches

    assert_equal 44, entries[0].tree.size
    assert connected?(found, 0, 1), found.map { |m| [m.a.entry.id, m.b.entry.id] }.inspect
    assert connected?(found, 0, 2)
    refute(found.any? { |m| [m.a.entry.id, m.b.entry.id].sort == [1, 2] })
  end

  # The run extends across one mismatched statement, here two big unlike
  # calls, which drags the extended run under the threshold. The exact core
  # of four statements is then judged on its own and found.
  # Contract: matcher/M3
  def test_an_exact_core_is_judged_when_its_extended_run_scores_under_the_threshold
    unlike = ["cache.write(key, subtotal, expires_in: 5.minutes, race_condition_ttl: 10, namespace: \"orders\")",
              "mailer.receipt(order).deliver_later(wait: 5.minutes, queue: :low, priority: 3, tags: [:a, :b])"]
    sources = unlike.each_with_index.map do |odd, i|
      method_source(i, (RUN + [odd, "flush!"]).map { |statement| "    #{statement}" }.join("\n"))
    end

    found = matches_for(sources)

    assert_equal [[:run, 5, 5]], kinds_and_starts(found)
    assert_equal [5, 8], [found[0].a.start_line, found[0].a.end_line]
    assert_equal [5, 8], [found[0].b.start_line, found[0].b.end_line]
  end

  # Two methods written so the first one's `end` and the second one's `def`
  # share line 10. They're identical, but a copy can't share a line with
  # what it copies.
  # Contract: matcher/M8
  def test_whole_units_sharing_a_line_are_never_paired
    body = BODY.map { |statement| "    #{statement}" }.join("\n")
    source = "class A\n  def first(items, user)\n#{body}\n  end; def second(items, user)\n#{body}\n  end\nend\n"
    entries = entries_for([source])
    assert_equal [[2, 10], [10, 18]], entries.map { |e| [e.unit.start_line, e.unit.end_line] }

    found = matches_for([source])

    refute(found.any? { |m| m.a.whole })
    assert(found.all? { |m| disjoint?(m) })
  end

  # A unit's key names its file, so the same identity defined in two files
  # is two locations, and a base pair keyed one way can't stand for the other.
  # Contract: gate/G4
  def test_keys_name_the_file_so_one_identity_in_two_files_is_two_locations
    source = method_source(0, FRAGMENT)
    entries = [source, source].each_with_index.flat_map do |text, i|
      Exhale::Units::Ruby.extract(text, "app/models/v#{i}/m0.rb")
    end.each_with_index.map do |unit, id|
      tree = Exhale::Dry::Fingerprints.build(Exhale::Dry::Normalizer.normalize(unit))
      Exhale::Dry::Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
    end
    index = Exhale::Dry::Index.new(entries)

    found = Exhale::Dry::Matcher.new(index, floors: SETTINGS, settings_for_pair: ->(*) { SETTINGS }).matches

    unit = found.find { |m| m.kind == :unit }
    assert_equal unit.a.unit.identity, unit.b.unit.identity
    refute_equal unit.a.key, unit.b.key
    assert_includes unit.a.key, "app/models/v0/m0.rb"
    assert_equal unit.a.structural_key, unit.b.structural_key
    fragment = Exhale::Dry::Location.new(entry: entries[0], start_line: 5, end_line: 10, size: 1, set: Set.new,
                                         whole: false, signature: 255, ordinal: 2)
    assert_equal "app/models/v0/m0.rb##{entries[0].unit.identity}@ff#2", fragment.key
    assert_equal "ff", fragment.structural_key
  end

  # The matcher exposes which identical copies it joined into one group.
  # Contract: matcher/M1
  def test_the_matcher_tells_which_identical_copies_it_joined
    twin = method_source(0, FRAGMENT)
    sources = [twin, twin.sub("class M0", "class T1"), method_source(2, FRAGMENT), twin.sub("class M0", "class T3")]
    matcher = Exhale::Dry::Matcher.new(Exhale::Dry::Index.new(entries_for(sources)), floors: SETTINGS,
                                       settings_for_pair: ->(*) { SETTINGS })

    matcher.matches

    twins = matcher.twins
    assert_equal 1, [0, 1, 3].map { |id| twins.fetch(id) }.uniq.size
    assert_includes [0, 1, 3], twins.fetch(0)
    refute twins.key?(2)
  end
end
