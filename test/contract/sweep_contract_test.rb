# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "exhale/dry/check"
require "exhale/report"

# The sweep's obligations, contract/sweep/README.md, each proved against a
# throwaway git repository with fixed commit dates.
class SweepContractTest < Minitest::Test
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

  def setup
    @dir = Dir.mktmpdir("exhale-sweep")
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

  def cache
    File.join(@dir, "tmp", "exhale")
  end

  def check(**options)
    Exhale::Dry::Check.new(root: @dir, base: "main", cache_dir: cache, **options).run
  end

  def report(**options)
    Exhale::Report.render(check(**options), "json")
  end

  # Value: protects=the head sweep reads every file, not only the ones the PR touched; fails_when=the sweep narrows to the diff and an old pair goes unreported; why_new=no test named the whole-codebase rule; seam=none
  # Contract: sweep/W1
  def test_a_pair_the_pr_never_touched_is_still_reported
    write("app/models/billing/invoice.rb", INVOICE)
    write("app/models/billing/receipt.rb", RECEIPT)
    commit("old pair")
    git("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", "class Shipment\n  def label = code\nend\n")
    commit("unrelated change")

    result = check

    assert_equal %w[app/models/billing/invoice.rb app/models/billing/receipt.rb],
                 [result.findings.fetch(0).copy, *result.findings.fetch(0).others.map(&:first)].map(&:path).sort
    assert_equal 1, result.exit_code
  end

  # Value: protects=a base cache warmed without tests never answers an --include-tests run; fails_when=the cache key leaves include_tests out, so the warm run calls an old pair shifted and the on-ramp fails; why_new=review proved a warm cache flipped an --include-tests --introduced-only run; seam=none
  # Contract: sweep/W2
  def test_the_cache_key_covers_whether_tests_are_included
    write("app/models/invoice.rb", INVOICE)
    write("test/support/receipt.rb", RECEIPT)
    commit("a copy in test support")
    git("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", "class Shipment\n  def label = code\nend\n")

    check # warms the cache without tests
    warm = report(include_tests: true, introduced_only: true)
    FileUtils.rm_rf(cache)
    cold = report(include_tests: true, introduced_only: true)

    assert_equal cold, warm
    assert_equal ["already_there"], JSON.parse(cold)["findings"].map { |f| f["class"] }
    assert_equal 0, JSON.parse(cold)["exit_code"]
  end

  # Value: protects=a base cache warmed with one Contract directory never answers a run with another; fails_when=the cache key leaves the Contract's directory out, so a clause already at the base reads as new; why_new=the cache key grew to cover contract_dir after review; seam=none
  # Contract: sweep/W2
  def test_the_cache_key_covers_the_contracts_directory
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    write("rules/billing/duplication.md", "## Totals stay separate\n\n```parallel\nInvoice\nReceipt\n```\n")
    commit("a clause under rules/")
    git("checkout", "-q", "-b", "feature")

    check # warms the cache reading contract/, which has no clauses
    warm = report(contract_dir: "rules")
    FileUtils.rm_rf(cache)
    cold = report(contract_dir: "rules")

    assert_equal cold, warm
    assert_equal [false], JSON.parse(cold)["kept"].map { |k| k["new_clause"] }
  end

  # Value: protects=apps in one monorepo can share a cache without reading each other's base; fails_when=the cache key leaves out where the app sits in its repository, so one app's summary labels the other's findings; why_new=review proved a shared --cache flipped an app's labels to SHIFTED; seam=two roots in one repository
  # Contract: sweep/W2
  def test_apps_in_one_repository_can_share_a_cache
    write("apps/a/app/models/invoice.rb", INVOICE)
    write("apps/a/app/models/receipt.rb", RECEIPT)
    shipment = "class Shipment\n  def label(parcel)\n    code = parcel.carrier.code\n    number = parcel.tracking_number\n" \
               "    weight = parcel.weight.round(2)\n    [code, number, weight].join(\"-\")\n  end\nend\n"
    write("apps/b/app/models/shipment.rb", shipment)
    write("apps/b/app/models/delivery.rb", shipment.sub("class Shipment", "class Delivery"))
    commit("two apps, each with an old pair")
    git("checkout", "-q", "-b", "feature")
    write("apps/b/app/models/note.rb", "class Note\n  def body = text\nend\n")
    commit("unrelated")

    shared = File.join(@dir, "tmp", "shared")
    run = lambda do |app, cache_dir|
      Exhale::Report.render(Exhale::Dry::Check.new(root: File.join(@dir, "apps", app), base: "main",
                                                   cache_dir: cache_dir).run, "json")
    end
    warm = %w[a b].to_h { |app| [app, run.call(app, shared)] }
    cold = %w[a b].to_h { |app| [app, run.call(app, File.join(@dir, "tmp", "private-#{app}"))] }

    assert_equal cold, warm
    %w[a b].each { |app| assert_equal ["already_there"], JSON.parse(cold[app])["findings"].map { |f| f["class"] } }
  end

  # Value: protects=one primitive's looser settings find its pairs without loosening anyone else's; fails_when=candidates are generated at the defaults, so a 3-line copy the primitive allows is never proposed, or the loose floor leaks to other code; why_new=floors had no end-to-end test; seam=none
  # Contract: sweep/W3
  def test_one_primitives_looser_settings_find_its_pairs_and_only_its_pairs
    three_lines = lambda do |namespace, klass|
      "module #{namespace}\n  class #{klass}\n    def total(items)\n" \
        "      items.select(&:billable?).sum { |item| item.amount * item.quantity + item.tax - item.discount }\n" \
        "    end\n  end\nend\n"
    end
    label = lambda do |klass|
      "module Shipping\n  class #{klass}\n    def label(parcel)\n" \
        "      [parcel.carrier.code, parcel.tracking_number, parcel.weight.round(2), parcel.zone&.name].compact.join(\"-\")\n" \
        "    end\n  end\nend\n"
    end
    write("app/models/billing/invoice.rb", three_lines.call("Billing", "Invoice"))
    write("app/models/billing/receipt.rb", three_lines.call("Billing", "Receipt"))
    write("app/models/shipping/parcel.rb", label.call("Parcel"))
    write("app/models/shipping/crate.rb", label.call("Crate"))
    write("contract/billing/README.md", "# Billing\n\n```covers\nBilling\n```\n")
    write("contract/billing/duplication.md", "## Short totals count\n\n```settings\nmin-lines: 3\n```\n")
    commit("three-line copies")

    found = check.findings.map { |f| [f.copy, *f.others.map(&:first)].map { |l| l.unit.identity }.sort }
    assert_equal [%w[Billing::Invoice#total Billing::Receipt#total]], found

    # The shipping pair is a real 3-line copy; only its own settings keep it out.
    loosened = check(overrides: { min_lines: 3 }).findings.flat_map { |f| [f.copy, *f.others.map(&:first)] }
    assert_includes loosened.map { |l| l.unit.identity }, "Shipping::Parcel#label"
  end

  def cache_files
    Dir[File.join(cache, "base-*")]
  end

  # An old pair on main, an unrelated change on the branch: already there
  # when the base is read right, shifted when a wrong summary is trusted.
  def an_old_pair
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("old pair")
    git("checkout", "-q", "-b", "feature")
    write("README.md", "docs only\n")
    commit("docs")
  end

  # Value: protects=the base cache is plain JSON and anything malformed in it is rebuilt; fails_when=the cache is a Marshal dump, which loading would execute, or a field of the wrong type is trusted or raises; why_new=Codex #8 and #18 proved Marshal.load read whatever sat at the cache path; seam=none
  # Contract: sweep/W2
  def test_the_cache_is_json_and_anything_malformed_is_rebuilt
    an_old_pair
    cold = report
    assert_equal 1, cache_files.size
    good = File.binread(cache_files.first)
    summary = JSON.parse(good)
    assert_kind_of Hash, summary

    variants = ["", "not json", "[]", "null", good[0, good.size / 2], Marshal.dump(summary)]
    variants.concat(summary.keys.flat_map { |key| [42, "x", nil, 1.5].map { |bad| JSON.generate(summary.merge(key => bad)) } })
    variants << JSON.generate(summary.merge("surprise" => true))
    summary.each do |key, value|
      if value.is_a?(Array) && !value.empty?
        variants << JSON.generate(summary.merge(key => [value.first.is_a?(Array) ? [nil] * value.first.size : [1, 2]]))
      elsif value.is_a?(Hash) && !value.empty?
        variants << JSON.generate(summary.merge(key => value.merge(value.keys.first => "x")))
      end
    end

    variants.each do |bad|
      File.binwrite(cache_files.first, bad)
      assert_equal cold, report, "trusted a malformed cache: #{bad[0, 80].inspect}"
      assert_equal good, File.binread(cache_files.first), "didn't rebuild after #{bad[0, 80].inspect}"
    end
  end

  # Value: protects=a cache row is trusted only when it is seven strings with a usable fraction in the third; fails_when=a row of the wrong size or with a bad score is trusted, or a good row is thrown away; why_new=the malformed-cache test only fed whole-field and shapeless rows; seam=none
  # Contract: sweep/W2
  def test_a_cache_row_is_seven_strings_with_a_usable_fraction
    row = %w[Invoice#totals Receipt#totals 4/5 app/a.rb app/b.rb x y]
    summary = Exhale::Dry::BaseSummary.new(clusters: { "k" => 1 }, structures: { "s" => [1, 2] },
                                           clause_keys: Set["c"], pairs: [[row[0], row[1], Rational(4, 5), *row[3..]]])
    good = Exhale::Dry::BaseCache.dump(summary)
    assert_equal summary, Exhale::Dry::BaseCache.load(good)

    bad_rows = [row[0, 6], row + ["z"], row.dup.tap { |r| r[2] = "x" }, row.dup.tap { |r| r[2] = "1/0" }, row.dup.tap { |r| r[3] = 7 }]
    bad_rows.each do |bad|
      json = JSON.generate(JSON.parse(good).merge("pairs" => [bad]))
      assert_nil Exhale::Dry::BaseCache.load(json), "trusted #{bad.inspect}"
    end
  end

  # Value: protects=a base cache that can't be written never fails the run or leaves a temp file behind; fails_when=the failed write's temp file stays in the cache directory; why_new=no test made the rename fail; seam=a directory sits where the cache file belongs, so the rename raises
  # Contract: sweep/W2
  def test_a_cache_that_cannot_be_written_is_skipped_and_leaves_no_temp_file
    an_old_pair
    cold = report
    path = cache_files.first
    File.delete(path)
    Dir.mkdir(path)

    assert_equal cold, report
    assert File.directory?(path)
    assert_empty Dir[File.join(cache, "*.tmp")]
  end

  # Value: protects=a cache path that is a symlink is neither trusted nor written through; fails_when=a summary planted behind a symlink labels the run, or a write overwrites the symlink's target; why_new=Codex #18 proved the cache followed symlinks both ways; seam=a second repository's summary planted behind the link
  # Contract: sweep/W2
  def test_a_symlinked_cache_is_never_trusted_or_written_through
    elsewhere = Dir.mktmpdir("exhale-elsewhere")
    planted = File.join(elsewhere, "planted")
    File.binwrite(planted, summary_of_a_base_without_the_pair(File.join(elsewhere, "repo")))
    an_old_pair
    cold = report
    path = cache_files.first
    File.delete(path)
    File.symlink(planted, path)
    before = File.binread(planted)

    assert_equal cold, report, "trusted a summary reached through a symlink"
    assert File.symlink?(path), "the symlink was replaced"
    assert_equal before, File.binread(planted), "the symlink's target was overwritten"
  ensure
    FileUtils.rm_rf(elsewhere) if elsewhere
  end

  # A real cache file, from a repository whose base holds only Invoice.
  def summary_of_a_base_without_the_pair(repo)
    own = @dir
    @dir = repo
    FileUtils.mkdir_p(repo)
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
    write("app/models/invoice.rb", INVOICE)
    commit("invoice only")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)
    commit("receipt")
    check
    File.binread(cache_files.fetch(0))
  ensure
    @dir = own
  end
end
