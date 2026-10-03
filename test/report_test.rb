# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "exhale/dry/check"
require "exhale/report"

class ReportTest < Minitest::Test
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
    @dir = Dir.mktmpdir("exhale-report")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @dir, *args)
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

  def check
    Exhale::Dry::Check.new(root: @dir, base: "main", cache_dir: File.join(@dir, "tmp", "exhale")).run
  end

  # Value: protects=the JSON and EDN machine formats (class, touched flags, exit_code, counts, EDN candidate rows) that tools and dryer consume; fails_when=a key is renamed or dropped, touched flags flip, or EDN loses its candidate shape; why_new=Report has no test and check_test only compares two json renders to each other; seam=none
  # Contract: report/R3
  def test_json_and_edn_describe_an_introduced_copy
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)
    result = check

    json = JSON.parse(Exhale::Report.render(result, "json"))
    assert_equal "dry", json["check"]
    assert_equal Exhale::VERSION, json["exhale"]
    assert_equal Exhale::Dry::Normalizer::VERSION, json["normalizer"]
    assert_equal 1, json["exit_code"]
    assert_equal 1, json.dig("counts", "introduced")
    assert_equal 0, json.dig("counts", "kept")
    finding = json["findings"].fetch(0)
    assert_equal "introduced", finding["class"]
    assert_equal "Receipt#totals", finding.dig("copy", "identity")
    assert_equal true, finding.dig("copy", "touched")
    assert_equal "Invoice#totals", finding["existing"].fetch(0)["identity"]
    assert_equal false, finding["existing"].fetch(0)["touched"]
    assert_equal [], json["parse_errors"]

    edn = Exhale::Report.render(result, "edn")
    assert_match(/\A\{:candidates\n \[\{:score /, edn)
    assert_includes edn, ':language "ruby"'
    assert_includes edn, ':file "app/models/receipt.rb"'
    assert_includes edn, ':file "app/models/invoice.rb"'

    assert_raises(ArgumentError) { Exhale::Report.render(result, "yaml") }
  end

  # Value: protects=the text report for a clause added in this branch (KEPT row, NEW CLAUSE flag, counts header, base sha); fails_when=new_clause is computed backwards, the KEPT row loses its clause location, or the header drops kept; why_new=kept/new_clause labeling against the base clause keys has no test; seam=none
  # Contract: report/R2
  def test_text_flags_a_clause_added_on_the_branch
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    write("contract/document_total/duplication.md", <<~MD)
      ## Totals stay separate

      Receipts and invoices total differently under some tax regimes.

      ```parallel
      Invoice
      Receipt
      ```
    MD
    result = check
    text = Exhale::Report.render(result, "text")

    assert_equal 0, result.exit_code, text
    assert_match(/\Aexhale dry: 1 kept   base [0-9a-f]{7}\n/, text)
    assert_match(%r{KEPT  [\d.]+  contract/document_total/duplication\.md:\d+ "Totals stay separate"  NEW CLAUSE, review its reason}, text)

    json = JSON.parse(Exhale::Report.render(result, "json"))
    assert_equal true, json["kept"].fetch(0)["new_clause"]
  end
end
