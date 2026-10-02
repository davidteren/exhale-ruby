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

  def test_prefix_filtering_finds_exactly_the_pairs_brute_force_finds
    entries = entries_for(corpus)
    index = Exhale::Dry::Index.new(entries)
    eligible = entries.select { |e| e.unit.lines >= 4 && e.tree.size >= 20 }

    brute = eligible.combination(2).select do |a, b|
      index.score(a.set, a.total, b.set, b.total) >= SETTINGS[:threshold]
    end.map { |a, b| [a.id, b.id] }.sort
    found = matcher(index).send(:unit_matches, eligible).map { |m| [m.a.entry.id, m.b.entry.id].sort }.sort

    refute_empty brute
    assert_equal brute, found
  end

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
end
