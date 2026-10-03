# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "exhale/dry/check"

# The gate's rule for groups of identical units (G8) and the labels that
# depend on how the base clustered its locations (G4, G5), each proved
# against a throwaway git repository.
class GateTwinsTest < Minitest::Test
  INVOICE = <<~RUBY
    class Invoice
      def totals(lines)
        subtotal = lines.sum { |line| line.amount * line.quantity }
        tax = subtotal * rate_for(region)
        discount = lines.select(&:discounted?).sum(&:discount)
        { subtotal: subtotal, tax: tax, discount: discount, total: subtotal + tax - discount }
      end
    end
  RUBY

  RECEIPT = <<~RUBY
    class Receipt
      def totals(items)
        net = items.sum { |item| item.amount * item.quantity }
        levy = net * rate_for(region)
        off = items.select(&:discounted?).sum(&:discount)
        { subtotal: net, tax: levy, discount: off, total: net + levy - off }
      end
    end
  RUBY

  # Scores between 0.5 and 0.8 against INVOICE.
  NEAR_RECEIPT = RECEIPT.sub("    off = items.select(&:discounted?).sum(&:discount)\n",
                             "    off = coupons.map(&:value).max.to_i\n")

  # Scores under 1 and over 0.8 against INVOICE.
  CLOSE_RECEIPT = RECEIPT.sub("    off = items", "    notify(net)\n    off = items")

  POSTING = <<-RUBY
    entries.each do |entry|
      amount = entry.debit - entry.credit
      balances[entry.account] += amount
      audit.log("posted \#{entry.id} \#{amount}")
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-twins")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    env = { "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }
    out, status = Open3.capture2e(env, "git", "-C", @dir, *args)
    raise out unless status.success?

    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
  end

  def check(**options)
    Exhale::Dry::Check.new(root: @dir, base: "main", cache_dir: File.join(@dir, "tmp", "exhale"), **options).run
  end

  # INVOICE's method, renamed, as many times as asked in one class.
  def identical(klass, *names)
    method = INVOICE.lines[1..-2].join
    "class #{klass}\n#{names.map { |name| method.sub('def totals', "def #{name}") }.join("\n")}end\n"
  end

  def identities(finding)
    [finding.copy, *finding.others.map(&:first)].map { |l| l.unit.identity }.sort
  end

  def settings_for(primitive, covers, settings)
    write("contract/#{primitive}/README.md", "```covers\n#{covers.join("\n")}\n```\n")
    write("contract/#{primitive}/duplication.md", "```settings\n#{settings}\n```\n")
  end

  # Value: protects=two base findings that a looser threshold joins at the head are shifted, because the untouched locations never sat in one base finding; fails_when=the base's union-find hands every location the same root, so any finding of old locations reads as already there; why_new=no test had two separate base clusters; seam=a Contract settings change, which touches no code
  # Contract: gate/G4
  def test_two_base_findings_joined_at_the_head_are_shifted
    write("app/models/invoice.rb", INVOICE)
    write("app/models/invoice_twin.rb", INVOICE.sub("class Invoice", "class InvoiceTwin"))
    write("app/models/near.rb", NEAR_RECEIPT)
    write("app/models/near_twin.rb", NEAR_RECEIPT.sub("class Receipt", "class NearTwin"))
    commit("two pairs, each its own finding")
    assert_equal 2, check.findings.size

    git("checkout", "-q", "-b", "feature")
    write("contract/billing/README.md", "```covers\nInvoice\nInvoiceTwin\nReceipt\nNearTwin\n```\n")
    write("contract/billing/duplication.md", "```settings\nthreshold: 0.5\n```\n")
    commit("loosen billing")

    finding = check.findings.fetch(0)

    assert_equal 4, 1 + finding.others.size
    assert_empty finding.touched
    assert_equal :shifted, finding.klass
  end

  # Value: protects=a pair that moves to another path still matches, so it isn't listed as contracted; fails_when=contraction counts the base rows as lost when the moved keys no longer line up; why_new=the contracted tests only removed or edited a side; seam=none
  # Contract: gate/G5
  def test_a_moved_copy_is_not_contracted
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("an old pair")
    git("checkout", "-q", "-b", "feature")
    git("mv", "app/models/receipt.rb", "app/models/sales_receipt.rb")
    commit("move the receipt")

    result = check

    assert_empty result.contracted
    assert_equal 1, result.findings.size
  end

  # Value: protects=a clause keeps a group of identical units only when it keeps every pair, so the pairs it does keep stay out of the findings; fails_when=a pair the clause keeps but the star never joined is reported as unkept; why_new=the existing G8 tests had a hub that happened to touch every kept pair; seam=none
  # Contract: gate/G8
  def test_pairs_a_clause_keeps_are_not_reported_when_the_star_skips_them
    write("app/models/a.rb", identical("A", "x", "y"))
    write("app/models/b.rb", identical("B", "x", "y"))
    write("contract/billing/duplication.md", "## A and B stay apart\n\n```parallel\nA\nB\n```\n")
    commit("A and B kept, each repeats itself")

    result = check

    assert_equal [%w[A#x A#y], %w[B#x B#y]], result.findings.map { |f| identities(f) }.sort
  end

  # Value: protects=a kept match between fragments doesn't expand into twins, since only whole units form identical groups; fails_when=a kept fragment pair is looked up as a group of units and the gate raises or reports pairs nobody matched; why_new=no test kept a fragment match; seam=none
  # Contract: gate/G8
  def test_a_kept_fragment_match_is_not_expanded
    ledger = "class Ledger\n  def post(entries)\n    header = build_header(entries, Time.now.utc)\n#{POSTING}    footer(header)\n  end\nend\n"
    journal = "class Journal\n  def record(entries)\n    return if entries.empty?\n\n    notify(entries.size)\n#{POSTING}  end\nend\n"
    write("app/models/ledger.rb", ledger)
    write("app/models/journal.rb", journal)
    write("contract/billing/duplication.md", "## Ledger and Journal stay apart\n\n```parallel\nLedger\nJournal\n```\n")
    commit("a posting loop in two classes, kept")

    result = check

    refute_empty result.kept
    assert_empty result.findings
    assert_equal 0, result.exit_code
  end

  # P and Q are identical, R is a near copy. A clause keeps P~R and another keeps
  # P~Q, so only Q~R is left for the gate to find.
  def twin_scenario(pair_source, lone_source)
    write("app/models/p.rb", pair_source.sub(/class \w+/, "class P"))
    write("app/models/q.rb", pair_source.sub(/class \w+/, "class Q"))
    write("app/models/r.rb", lone_source.sub(/class \w+/, "class R"))
    write("contract/billing/duplication.md", "## P and R\n\n```parallel\nP\nR\n```\n\n## P and Q\n\n```parallel\nP\nQ\n```\n")
    commit("P kept with Q and with R")
    check
  end

  # Value: protects=a match a clause keeps from a group's hub doesn't vouch for the group's other members, and the pair that surfaces scores what the hubs scored, whichever of the two digests sorts first; fails_when=the expansion is skipped when the larger group of the pair sorts first, or the unkept pair scores 1 instead of the hubs' score; why_new=the digest order decides which side is larger and the older test saw one order and never read the score; seam=none
  # Contract: gate/G8
  def test_a_kept_match_vouches_for_no_twin_when_the_group_is_the_invoice
    result = twin_scenario(INVOICE, CLOSE_RECEIPT)

    assert_equal [%w[Q#totals R#totals]], result.findings.map { |f| identities(f) }
    assert_operator result.findings.first.score, :<, 1
  end

  # Value: protects=the same rule as above with the group and the lone copy swapped; fails_when=see above; why_new=the digest order decides which side is larger, so each order needs its own repository; seam=none
  # Contract: gate/G8
  def test_a_kept_match_vouches_for_no_twin_when_the_group_is_the_close_copy
    result = twin_scenario(CLOSE_RECEIPT, INVOICE)

    assert_equal [%w[Q#totals R#totals]], result.findings.map { |f| identities(f) }
    assert_operator result.findings.first.score, :<, 1
  end

  # P is in the default primitive; Q and R are in "strict". A clause keeps P~Q,
  # so P~R and Q~R are left, and Q~R has to meet strict's own settings.
  def strict_scenario(strict_settings)
    write("app/models/p.rb", identical("P", "totals"))
    write("app/models/q.rb", identical("Q", "totals"))
    write("app/models/r.rb", identical("R", "totals"))
    settings_for("strict", %w[Q R], strict_settings)
    write("contract/billing/duplication.md", "## P and Q\n\n```parallel\nP\nQ\n```\n")
    commit("P kept with Q")
    check
  end

  # Value: protects=an unkept pair the star never joined meets its own settings, so a pair of units under a stricter min_lines isn't reported; fails_when=twin pairs skip the size floors; why_new=every earlier twin was judged under default settings; seam=a Contract settings block
  # Contract: gate/G8
  def test_a_twin_pair_meets_its_own_min_lines
    reported = strict_scenario("min-lines: 1")
    lines = reported.findings.fetch(0).copy.lines
    assert_equal %w[P#totals Q#totals R#totals], identities(reported.findings.fetch(0))

    FileUtils.rm_rf(@dir)
    setup
    result = strict_scenario("min-lines: #{lines + 1}")

    assert_equal [%w[P#totals R#totals]], result.findings.map { |f| identities(f) }
  end

  # Q, R and S are three identical units in "strict". The matcher joins them
  # through Q, so R~S is no match of its own; a clause keeps Q~R, which
  # leaves R~S for the gate to bring back under strict's own settings.
  def three_strict(strict_settings)
    %w[Q R S].each { |name| write("app/models/#{name.downcase}.rb", identical(name, "totals")) }
    settings_for("strict", %w[Q R S], strict_settings)
    write("contract/billing/duplication.md", "## Q and R\n\n```parallel\nQ\nR\n```\n")
    commit("Q kept with R")
    check
  end

  # Value: protects=a twin pair sitting exactly on its min-lines and min-nodes is reported; fails_when=a floor compares with > and drops the pair at the boundary; why_new=no test put a floor on the edge; seam=a Contract settings block
  # Contract: gate/G8
  def test_a_twin_pair_on_its_floors_is_reported
    probe = three_strict("min-lines: 1")
    assert_equal [%w[Q#totals R#totals S#totals]], probe.findings.map { |f| identities(f) }
    location = probe.findings.fetch(0).copy
    FileUtils.rm_rf(@dir)
    setup

    on_lines = three_strict("min-lines: #{location.lines}\nmin-nodes: 1")
    FileUtils.rm_rf(@dir)
    setup
    on_nodes = three_strict("min-lines: 1\nmin-nodes: #{location.size}")

    assert_equal [%w[Q#totals R#totals S#totals]], on_lines.findings.map { |f| identities(f) }
    assert_equal [%w[Q#totals R#totals S#totals]], on_nodes.findings.map { |f| identities(f) }
  end

  # Value: protects=identical twins clear a threshold of 1, because their score is 1; fails_when=the threshold test rejects a score equal to the threshold; why_new=no test set the threshold to 1; seam=a Contract settings block
  # Contract: gate/G8
  def test_identical_twins_clear_a_threshold_of_one
    result = three_strict("threshold: 1")

    assert_equal [%w[Q#totals R#totals S#totals]], result.findings.map { |f| identities(f) }
  end

  # Value: protects=a twin pair under a stricter min_nodes isn't reported even when its lines clear the floor; fails_when=the two floors are joined with or, so one passing floor lets the pair through; why_new=every earlier twin passed both floors; seam=a Contract settings block
  # Contract: gate/G8
  def test_a_twin_pair_meets_its_own_min_nodes
    probe = strict_scenario("min-lines: 1")
    size = probe.findings.fetch(0).copy.size
    FileUtils.rm_rf(@dir)
    setup

    result = strict_scenario("min-lines: 1\nmin-nodes: #{size + 1}")

    assert_equal [%w[P#totals R#totals]], result.findings.map { |f| identities(f) }
  end

  # Value: protects=a twin pair across two groups meets its own threshold, the hubs' score notwithstanding; fails_when=the twin skips the threshold and a pair under strict's threshold is reported; why_new=every earlier twin passed the default threshold; seam=a Contract settings block
  # Contract: gate/G8
  def test_a_twin_across_groups_meets_its_own_threshold
    write("app/models/p.rb", identical("P", "totals"))
    write("app/models/q.rb", identical("Q", "totals"))
    write("app/models/r.rb", CLOSE_RECEIPT.sub(/class \w+/, "class R"))
    settings_for("strict", %w[Q R], "threshold: 0.99")
    write("contract/billing/duplication.md", "## P and R\n\n```parallel\nP\nR\n```\n")
    commit("P kept with R")

    result = check

    assert_equal [%w[P#totals Q#totals]], result.findings.map { |f| identities(f) }
  end
end
