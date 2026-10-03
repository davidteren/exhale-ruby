# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "exhale/dry/check"
require "exhale/report"

# The report's obligations, contract/report/README.md, each proved against a
# throwaway git repository with fixed commit dates.
class ReportContractTest < Minitest::Test
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

  SHIPMENT = <<~RUBY
    class Shipment
      def label(parcel)
        code = parcel.carrier.code
        number = parcel.tracking_number
        weight = parcel.weight.round(2)
        [code, number, weight].join("-")
      end
    end
  RUBY

  COUPON = <<~RUBY
    class Coupon
      def redeem(order)
        return false if expired? || order.total < minimum

        order.discounts << self
        self.uses += 1
        save!
      end
    end
  RUBY

  STATEMENT = <<~RUBY
    class Statement
      def render(account)
        opening = account.balance_at(period.start)
        closing = account.balance_at(period.finish)
        credits = account.entries.select(&:credit?).sum(&:amount)
        { opening: opening, closing: closing, credits: credits }
      end
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-report")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args, dir: @dir)
    env = { "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }
    out, status = Open3.capture2e(env, "git", "-C", dir, *args)
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

  def check(root: @dir)
    Exhale::Dry::Check.new(root: root, base: "main", cache_dir: File.join(root, "tmp", "exhale")).run
  end

  def renamed(source, from, to)
    source.sub("class #{from}", "class #{to}")
  end

  # A branch with an introduced, an already-there, a kept and a contracted
  # pair, so every section of the report has something in it.
  def every_label
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    write("app/models/shipment.rb", SHIPMENT)
    write("app/models/coupon.rb", COUPON)
    write("app/models/voucher.rb", renamed(COUPON, "Coupon", "Voucher"))
    write("app/models/statement.rb", STATEMENT)
    write("app/models/summary.rb", renamed(STATEMENT, "Statement", "Summary"))
    write("contract/reporting/duplication.md", "## Statements stay apart\n\n```parallel\nStatement\nSummary\n```\n")
    commit("base")
    git("checkout", "-q", "-b", "feature")
    write("app/models/parcel.rb", renamed(SHIPMENT, "Shipment", "Parcel"))
    git("rm", "-q", "app/models/voucher.rb")
    commit("feature")
  end

  # Value: protects=text names both sides of a finding by path, lines and identity, marks the copy, and gives one hint; fails_when=a side loses its path, lines or identity, the copy and existing rows swap marks, or a finding prints no hint or two; why_new=only the new side's row had a test; seam=none
  # Contract: report/R1
  def test_text_names_both_sides_marks_the_copy_and_gives_one_hint
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("an old pair")
    git("checkout", "-q", "-b", "feature")
    write("app/models/quote.rb", renamed(INVOICE, "Invoice", "Quote"))

    text = Exhale::Report.render(check, "text")
    blocks = text.split("\n\n").drop(1)

    assert_equal 1, blocks.size, text
    rows = blocks.first.lines.map(&:rstrip)
    assert_match(/\AINTRODUCED  1\.0  method\z/, rows[0])
    assert_match(%r{\A  new       app/models/quote\.rb:2-7 +Quote#totals\z}, rows[1])
    assert_equal 2, rows.count { |row| row.match?(%r{\A  existing  app/models/(invoice|receipt)\.rb:2-7 +(Invoice|Receipt)#totals  1\.0\z}) }
    assert_equal ["  hint      extend or call Invoice#totals"], rows.grep(/\A  hint/)

    commit("the copy lands")
    git("checkout", "-q", "main")
    git("merge", "-q", "--ff-only", "feature")
    untouched = Exhale::Report.render(check, "text")
    assert_match(%r{^  copy      app/models/(quote|receipt)\.rb:2-7 }, untouched)
    refute_match(/^  new /, untouched)
  end

  # Value: protects=the header counts every label and every Contract error, and says clean only when the run exits 0; fails_when=a run failing only on a stale clause or a parse error reads "clean"; why_new=review proved a stale-clause run exited 1 under a "clean" header; seam=none
  # Contract: report/R2
  def test_the_header_says_clean_only_when_the_run_exits_zero
    write("app/models/invoice.rb", INVOICE)
    write("app/models/shipment.rb", SHIPMENT)
    write("contract/billing/duplication.md", "## Old\n\n```parallel\nInvoice\nShipment\n```\n")
    commit("a stale clause")

    stale = check
    assert_equal 1, stale.exit_code
    assert_equal "exhale dry: 1 contract error", Exhale::Report.render(stale, "text").lines.first.split("   base").first

    FileUtils.rm_rf(File.join(@dir, "contract"))
    write("app/models/broken.rb", "class Broken\n  def x(\nend\n")
    broken = check
    assert_equal 2, broken.exit_code
    assert_equal "exhale dry: 1 parse error", Exhale::Report.render(broken, "text").lines.first.split("   base").first

    FileUtils.rm_f(File.join(@dir, "app/models/broken.rb"))
    clean = check
    assert_equal 0, clean.exit_code
    assert_match(/\Aexhale dry: clean   base \h{7}\n/, Exhale::Report.render(clean, "text"))
  end

  # Value: protects=the header counts each label the run produced; fails_when=a label or the contracted count drops out of the header; why_new=headers were only tested with one label at a time; seam=none
  # Contract: report/R2
  def test_the_header_counts_every_label
    every_label

    header = Exhale::Report.render(check, "text").lines.first

    assert_equal "exhale dry: 1 introduced, 1 already there, 1 kept, 1 contracted", header.split("   base").first
  end

  # Value: protects=JSON carries the exhale and normalizer versions with the findings; fails_when=either version key is dropped or renamed, or findings stop matching the result; why_new=the JSON test never checked versions; seam=none
  # Contract: report/R3
  def test_json_carries_both_versions_and_the_findings_as_data
    every_label
    result = check

    json = JSON.parse(Exhale::Report.render(result, "json"))

    assert_equal Exhale::VERSION, json["exhale"]
    assert_equal Exhale::Dry::Normalizer::VERSION, json["normalizer"]
    assert_equal result.findings.map { |f| [f.klass.to_s, f.copy.unit.identity, f.hint] },
                 json["findings"].map { |f| [f["class"], f.dig("copy", "identity"), f["hint"]] }
  end

  # Value: protects=the same result renders byte for byte the same, across renders, cold and warm runs, and clones at other paths; fails_when=any format carries hash order, absolute paths, times or cache state; why_new=only two cold JSON runs were compared; seam=a second clone
  # Contract: report/R4
  def test_the_same_result_renders_byte_for_byte_the_same
    every_label
    clone = Dir.mktmpdir("exhale-clone")
    git("clone", "-q", "--branch", "feature", @dir, File.join(clone, "elsewhere"), dir: clone)
    git("branch", "-q", "main", "origin/main", dir: File.join(clone, "elsewhere"))

    first = check
    runs = [first, first, check, check(root: File.join(clone, "elsewhere"))]

    %w[text json edn].each do |format|
      renders = runs.map { |result| Exhale::Report.render(result, format) }
      assert_equal 1, renders.uniq.size, "#{format} differs between renders"
    end
  ensure
    FileUtils.rm_rf(clone) if clone
  end

  # Value: protects=the whole text layout: one existing side carries no score, kept sides, the contracted list, and every Contract and parse error, each section after one blank line; fails_when=a section loses its separator, a single existing side or a kept side grows a score, the contracted list miscounts its overflow, or Contract errors drop out of the body; why_new=only rows and headers were matched, so section layout and the error body had no test; seam=none
  # Contract: report/R1
  def test_text_lays_out_every_section_in_order
    every_label
    write("contract/shipping/duplication.md", "## Old\n\n```parallel\nShipment\nCoupon\n```\n")
    write("app/models/broken.rb", "class Broken\n  def x(\nend\n")

    text = Exhale::Report.render(check, "text").sub(/   base \h{7}\n/, "   base SHA\n")
    *lines, parse = text.lines

    assert_equal <<~TEXT, lines.join
      exhale dry: 1 introduced, 1 already there, 1 kept, 1 contracted, 1 contract error, 1 parse error   base SHA

      INTRODUCED  1.0  method
        new       app/models/parcel.rb:2-7    Parcel#label
        existing  app/models/shipment.rb:2-7  Shipment#label
        hint      extend or call Shipment#label

      ALREADY THERE  1.0  method
        copy      app/models/receipt.rb:2-7  Receipt#totals
        existing  app/models/invoice.rb:2-7  Invoice#totals
        hint      extend or call Invoice#totals

      KEPT  1.0  contract/reporting/duplication.md:3 "Statements stay apart"
        side      app/models/statement.rb:2-7  Statement#render
        side      app/models/summary.rb:2-7    Summary#render

      CONTRACTED
        Coupon#redeem no longer matches Voucher#redeem (1.0 at base)

      CONTRACT  contract/shipping/duplication.md:3: stale clause: nothing it covers duplicates anything over the threshold; delete it
    TEXT
    assert_match(%r{\APARSE     app/models/broken\.rb:3: .+\n\z}, parse)
  end

  # Value: protects=a clean run's text is its header alone, with no trailing sections; fails_when=an empty errors section still prints its separator; why_new=clean runs were only matched by their first line; seam=none
  # Contract: report/R2
  def test_a_clean_run_is_its_header_alone
    write("app/models/invoice.rb", INVOICE)
    commit("one class")

    assert_match(/\Aexhale dry: clean   base \h{7}\n\z/, Exhale::Report.render(check, "text"))
  end
end
