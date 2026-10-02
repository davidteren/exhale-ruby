# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "exhale/dry/check"
require "exhale/report"

class CheckTest < Minitest::Test
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

  UNRELATED = <<~RUBY
    class Shipment
      def label
        [carrier.code, tracking_number].join("-")
      end
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-check")
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

  def test_a_new_copy_is_introduced_and_fails_the_gate
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)

    result = check

    assert_equal 1, result.exit_code
    finding = result.findings.fetch(0)
    assert_equal :introduced, finding.klass
    assert_equal "Receipt#totals", finding.copy.unit.identity
    assert_equal "Invoice#totals", finding.others.fetch(0)[0].unit.identity
    assert_match(/extend or call Invoice#totals/, finding.hint)
  end

  def test_a_contract_clause_keeps_deliberate_duplication
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    write("contract/document_total/duplication.md", <<~MD)
      ## Totals stay separate

      Receipts and invoices total differently under some tax regimes.

      ```parallel
      Invoice
      Receipt
      ```
    MD
    commit("both")

    result = check

    assert_equal 0, result.exit_code, Exhale::Report.render(result, "text")
    assert_empty result.findings
    assert_equal 1, result.kept.size
    assert_equal "Totals stay separate", result.kept.first.clause.heading
  end

  def test_a_stale_clause_fails_the_gate
    write("app/models/invoice.rb", INVOICE)
    write("app/models/shipment.rb", UNRELATED)
    write("contract/document_total/duplication.md", "## Old\n\n```parallel\nInvoice\nShipment\n```\n")
    commit("stale")

    result = check

    assert_equal 1, result.exit_code
    assert_match(/stale clause/, result.clause_errors.first.message)
  end

  def test_duplication_already_on_main_fails_unless_the_on_ramp_is_on
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", UNRELATED)

    whole = check
    ramp = check(introduced_only: true)

    assert_equal :already_there, whole.findings.first.klass
    assert_equal 1, whole.exit_code
    assert_equal 0, ramp.exit_code
  end

  def test_the_same_commit_gets_the_same_report
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")

    first = Exhale::Report.render(check, "json")
    FileUtils.rm_rf(File.join(@dir, "tmp"))
    second = Exhale::Report.render(check, "json")

    assert_equal first, second
  end
end
