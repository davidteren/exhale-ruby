# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "exhale/dry/check"
require "exhale/report"

# The gate's obligations, contract/gate/README.md, each proved against a
# throwaway git repository with fixed commit dates.
class GateContractTest < Minitest::Test
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

  # INVOICE with one statement changed: it scores between 0.5 and 0.8
  # against INVOICE, so only a looser threshold matches the pair.
  NEAR_RECEIPT = RECEIPT.sub("    off = items.select(&:discounted?).sum(&:discount)\n",
                             "    off = coupons.map(&:value).max.to_i\n").freeze

  # Bigger than INVOICE, so its payoff is bigger too.
  STATEMENT = <<~RUBY
    class Statement
      def render(account)
        opening = account.balance_at(period.start)
        closing = account.balance_at(period.finish)
        credits = account.entries.select(&:credit?).sum(&:amount)
        debits = account.entries.select(&:debit?).sum(&:amount)
        fees = account.entries.select(&:fee?).sum(&:amount)
        interest = account.entries.select(&:interest?).sum(&:amount)
        lines = account.entries.map { |entry| [entry.date, entry.memo, entry.amount] }
        { opening: opening, closing: closing, credits: credits, debits: debits, fees: fees, lines: lines }
      end
    end
  RUBY

  # Smaller than INVOICE.
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

  # A fragment that sits inside methods that otherwise differ.
  POSTING = <<-RUBY
    entries.each do |entry|
      amount = entry.debit - entry.credit
      balances[entry.account] += amount
      audit.log("posted \#{entry.id} \#{amount}")
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-gate")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    date = @date || "2026-01-01T00:00:00Z"
    env = { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date }
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

  def check(root: @dir, **options)
    Exhale::Dry::Check.new(root: root, base: ("main" if root == @dir), cache_dir: File.join(root, "tmp", "exhale"),
                           **options).run
  end

  def json(result)
    JSON.parse(Exhale::Report.render(result, "json"))
  end

  def renamed(source, from, to)
    source.sub("class #{from}", "class #{to}")
  end

  def ledger(postings)
    "class Ledger\n  def post(entries)\n    header = build_header(entries, Time.now.utc)\n" \
      "#{POSTING}    footer(header)\n#{POSTING * (postings - 1)}  end\nend\n"
  end

  JOURNAL = "class Journal\n  def record(entries)\n    return if entries.empty?\n\n    notify(entries.size)\n" \
            "#{POSTING}  end\nend\n".freeze

  # INVOICE's method, renamed, as many times as asked in one class.
  def identical(klass, *names)
    method = INVOICE.lines[1..-2].join
    "class #{klass}\n#{names.map { |name| method.sub('def totals', "def #{name}") }.join("\n")}end\n"
  end

  # Three methods where A~B and B~C clear 0.80 and A~C doesn't, so the
  # base finding holds A and C only through B.
  def chain(klass, *extra)
    body = CHAIN[0..2] + extra + CHAIN[3..]
    "class #{klass}\n  def totals(lines)\n#{body.map { |line| "    #{line}\n" }.join}  end\nend\n"
  end

  CHAIN = ["subtotal = lines.sum { |line| line.amount * line.quantity }", "tax = subtotal * rate_for(region)",
           "discount = lines.select(&:discounted?).sum(&:discount)", "shipping = lines.map(&:weight).sum * carrier.rate",
           "handling = lines.count * fee_for(:handling)",
           "{ subtotal: subtotal, tax: tax, discount: discount, total: subtotal + tax - discount }"].freeze

  def identities(finding)
    [finding.copy, *finding.others.map(&:first)].map { |l| l.unit.identity }.sort
  end

  # Runs the block with the user's global git config replaced by a file
  # holding only these settings, so the machine's own config can't leak in.
  def with_git_config(settings)
    path = File.join(@dir, "tmp", "gitconfig-#{settings.keys.join('-')}")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, settings.empty? ? "" : "[diff]\n#{settings.map { |k, v| "\t#{k} = #{v}\n" }.join}")
    previous = ENV.fetch("GIT_CONFIG_GLOBAL", nil)
    ENV["GIT_CONFIG_GLOBAL"] = path
    yield
  ensure
    previous ? ENV["GIT_CONFIG_GLOBAL"] = previous : ENV.delete("GIT_CONFIG_GLOBAL")
  end

  # Value: protects=a commit's verdict and labels are the same on every machine; fails_when=diff.mnemonicPrefix or diff.noprefix in the user's config changes which lines count as touched; why_new=review proved a mnemonicPrefix config turned an introduced copy into a shifted one; seam=GIT_CONFIG_GLOBAL
  # Contract: gate/G1
  def test_the_users_git_config_never_changes_the_verdict
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)
    commit("receipt") # committed, so the diff decides what's touched, not the untracked list

    reports = [{}, { "mnemonicPrefix" => "true" }, { "noprefix" => "true" }].to_h do |settings|
      report = with_git_config(settings) do
        FileUtils.rm_rf(File.join(@dir, "tmp", "exhale"))
        Exhale::Report.render(check, "json")
      end
      [settings, report]
    end

    default = JSON.parse(reports.fetch({}))
    assert_equal "introduced", default["findings"].fetch(0)["class"]
    assert_equal 1, default["exit_code"]
    reports.each { |settings, report| assert_equal reports.fetch({}), report, "git config #{settings} changed the report" }
  end

  # Value: protects=a file whose name holds a space is still read as touched; fails_when=the tab git appends to such a header path stays on the path; why_new=review proved a new copy in "sales receipt.rb" was labeled shifted; seam=none
  # Contract: gate/G1
  # Contract: gate/G3
  def test_a_new_copy_in_a_path_with_a_space_is_introduced
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/sales receipt.rb", RECEIPT)
    commit("receipt")

    finding = check.findings.fetch(0)

    assert_equal :introduced, finding.klass
    assert_equal "app/models/sales receipt.rb", finding.copy.path
    assert_equal ["app/models/sales receipt.rb"], finding.touched.map(&:path)
  end

  # Value: protects=a PR can't hide a new copy behind an old pair by also editing an old copy; fails_when=the finding is labeled by the copy/original pair alone and reads already there; why_new=review proved editing Receipt while adding Quote passed as already there; seam=none
  # Contract: gate/G3
  def test_editing_an_old_copy_cannot_hide_a_new_copy_beside_it
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT.gsub("levy", "duty")) # still a copy, now touched
    write("app/models/quote.rb", renamed(INVOICE, "Invoice", "Quote")) # sorts before receipt.rb
    commit("edit one, add one")

    result = check

    assert_equal 1, result.findings.size
    finding = result.findings.fetch(0)
    assert_equal :introduced, finding.klass
    assert_equal %w[app/models/quote.rb app/models/receipt.rb], finding.touched.map(&:path).sort
    assert_equal 1, result.exit_code
  end

  # Value: protects=a second copy of a fragment inside a method that already held one is new; fails_when=fragment keys ignore which occurrence they are, so the new copy reads as the old one; why_new=review proved a duplicated block inside Ledger#post passed as already there; seam=none
  # Contract: gate/G3
  def test_a_second_copy_of_a_fragment_in_the_same_method_is_introduced
    write("app/models/ledger.rb", ledger(1))
    write("app/models/journal.rb", JOURNAL)
    commit("one posting each")
    assert_equal [:already_there], check.findings.map(&:klass)

    git("checkout", "-q", "-b", "feature")
    write("app/models/ledger.rb", ledger(2))
    commit("a second posting in the ledger")

    finding = check.findings.fetch(0)

    assert_equal :introduced, finding.klass
    assert_equal :fragment, finding.kind
    assert_equal "Ledger#post", finding.copy.unit.identity
    assert_equal [finding.copy], finding.touched
    assert_equal 2, finding.others.size
  end

  # Value: protects=0 clean, 1 for an unkept finding or a bad clause, 2 for a tree exhale can't read; fails_when=a kept-only run fails, a clause error passes, or a parse error reads as a gate result; why_new=the three codes were only tested one at a time through the CLI; seam=none
  # Contract: gate/G2
  def test_exit_codes_separate_clean_failing_and_unable_to_run
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    assert_equal 0, check.exit_code

    write("app/models/receipt.rb", RECEIPT)
    assert_equal 1, check.exit_code

    write("contract/billing/duplication.md", "## Kept\n\n```parallel\nInvoice\nReceipt\n```\n")
    assert_equal 0, check.exit_code

    write("contract/billing/duplication.md", "## Kept\n\n```parallel\nInvoice\nReceipt\nNobody\n```\n")
    assert_equal 1, check.exit_code

    FileUtils.rm_rf(File.join(@dir, "contract"))
    FileUtils.rm_f(File.join(@dir, "app/models/receipt.rb"))
    write("app/models/broken.rb", "class Broken\n  def x(\nend\n")
    assert_equal 2, check.exit_code
  end

  # Value: protects=an untouched pair the base never matched is shifted, and the on-ramp still fails on it; fails_when=an untouched new match reads as already there, or the on-ramp lets a shifted finding through; why_new=no test produced a shifted finding; seam=a Contract settings change, which touches no code
  # Contract: gate/G4
  # Contract: gate/G7
  def test_an_untouched_pair_that_newly_matches_is_shifted
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", NEAR_RECEIPT)
    write("contract/billing/README.md", "# Billing\n\n```covers\nInvoice\nReceipt\n```\n")
    commit("a near copy, under the threshold")
    assert_empty check.findings

    git("checkout", "-q", "-b", "feature")
    write("contract/billing/duplication.md", "## Looser\n\n```settings\nthreshold: 0.5\n```\n")
    commit("loosen billing")

    result = check

    finding = result.findings.fetch(0)
    assert_equal :shifted, finding.klass
    assert_empty finding.touched
    assert_equal 1, result.exit_code
    assert_equal 1, check(introduced_only: true).exit_code
  end

  # Value: protects=a pair only a flag override surfaces is labeled against a base swept with the same flags; fails_when=the base sweep ignores the overrides, so an unchanged old pair reads as shifted; why_new=review proved --threshold 0.5 labeled an untouched old pair SHIFTED; seam=none
  # Contract: gate/G6
  # Contract: gate/G4
  def test_a_pair_only_the_flags_surface_is_labeled_against_the_same_flags
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", NEAR_RECEIPT)
    commit("a near copy, under the threshold")
    git("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", SHIPMENT)
    commit("unrelated")
    assert_empty check.findings

    result = check(overrides: { threshold: Rational(1, 2) })

    finding = result.findings.fetch(0)
    assert_equal %w[Invoice#totals Receipt#totals], [finding.copy, *finding.others.map(&:first)].map { |l| l.unit.identity }.sort
    assert_operator finding.score, :<, Rational(4, 5)
    assert_empty finding.touched
    assert_equal :already_there, finding.klass
    assert_equal 0, result.exit_code
  end

  # Value: protects=the on-ramp fails on introduced findings and lists already-there ones as warnings; fails_when=the on-ramp passes a new copy, drops already-there findings from the report, or omits its note; why_new=the on-ramp was only tested on an already-there finding; seam=none
  # Contract: gate/G7
  def test_the_on_ramp_fails_on_introduced_and_warns_on_already_there
    write("app/models/statement.rb", STATEMENT)
    write("app/models/summary.rb", renamed(STATEMENT, "Statement", "Summary"))
    write("app/models/invoice.rb", INVOICE)
    commit("old duplication")
    git("checkout", "-q", "-b", "feature")

    warned = check(introduced_only: true)
    assert_equal 0, warned.exit_code
    assert_equal [:already_there], warned.findings.map(&:klass)
    assert_includes warned.notes, "introduced-only on-ramp: already-there findings are warnings"

    write("app/models/receipt.rb", RECEIPT)
    failing = check(introduced_only: true)
    assert_equal 1, failing.exit_code
    assert_equal %i[introduced already_there], failing.findings.map(&:klass)
  end

  # Value: protects=a pair that stops matching because one side diverged is contracted; fails_when=only deletions count as contracting; why_new=the contracted test only deletes a copy; seam=none
  # Contract: gate/G5
  def test_a_copy_that_diverges_is_contracted
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", "class Receipt\n  def totals(items)\n    items.map(&:to_h)\n  end\nend\n")

    result = check

    assert_empty result.findings
    assert_equal [%w[Invoice#totals Receipt#totals]], result.contracted.map { |c| [c.a, c.b].sort }
  end

  # Value: protects=with no git, the copy is the last location by path; fails_when=the copy falls back to identity, write order or the first path; why_new=the no-git branch of the copy rule had no test; seam=a plain directory
  # Contract: gate/G9
  def test_without_git_the_copy_is_the_last_by_path
    plain = Dir.mktmpdir("exhale-plain")
    File.write(File.join(plain, "z_invoice.rb"), INVOICE)
    File.write(File.join(plain, "a_receipt.rb"), RECEIPT)

    finding = check(root: plain).findings.fetch(0)

    assert_equal :found, finding.klass
    assert_equal "z_invoice.rb", finding.copy.path
    assert_equal "Invoice#totals", finding.copy.unit.identity
  ensure
    FileUtils.rm_rf(plain)
  end

  # Value: protects=payoff weighs every non-original location's nodes by score, and findings sort by label before payoff; fails_when=payoff counts the original, ignores score, or a big already-there finding sorts above a small introduced one; why_new=ordering and payoff values had no test; seam=none
  # Contract: gate/G10
  def test_findings_sort_by_label_then_payoff
    write("app/models/statement.rb", STATEMENT)
    write("app/models/summary.rb", renamed(STATEMENT, "Statement", "Summary"))
    write("app/models/invoice.rb", INVOICE)
    write("app/models/shipment.rb", SHIPMENT)
    commit("originals")
    git("checkout", "-q", "-b", "feature")
    write("app/models/delivery.rb", renamed(SHIPMENT, "Shipment", "Delivery"))
    %w[Receipt Quote].each { |name| write("app/models/#{name.downcase}.rb", renamed(INVOICE, "Invoice", name)) }

    findings = json(check)["findings"]

    assert_equal %w[introduced introduced already_there], findings.map { |f| f["class"] }
    assert_equal [%w[Invoice#totals Quote#totals Receipt#totals], %w[Delivery#label Shipment#label],
                  %w[Statement#render Summary#render]],
                 findings.map { |f| [f["copy"], *f["existing"]].map { |l| l["identity"] }.sort }
    payoffs = findings.map { |f| f["payoff"] }
    assert_operator payoffs[0], :>, payoffs[1]
    assert_operator payoffs[2], :>, payoffs[1], "a bigger already-there finding still sorts after introduced ones"
    # Every copy scores 1.0 here, so payoff is the nodes of every location but the original.
    findings.each do |f|
      locations = [f["copy"], *f["existing"]]
      assert_equal locations.sum { |l| l["nodes"] } - locations.map { |l| l["nodes"] }.max, f["payoff"]
    end
  end

  # Value: protects=hints come from the unit kinds and paths in the finding; fails_when=a fragment shared in one class stops saying extract a method, a cross-class fragment loses its concern or service hint, or a fully new pair loses the promote hint; why_new=only the whole-method hint had a test; seam=none
  # Contract: gate/G11
  def test_ruby_hints_follow_fixed_rules
    write("app/models/ledger.rb", ledger(1))
    write("app/models/journal.rb", JOURNAL)
    write("app/services/payout.rb", "class Payout\n  def settle(entries)\n    lock!\n#{POSTING}  end\nend\n")
    write("app/services/refund.rb", "class Refund\n  def apply(entries)\n    raise Locked if locked?\n\n#{POSTING}  end\nend\n")
    commit("fragments")

    hints = check.findings.map(&:hint).sort
    assert_equal ["4 copies in 4 classes; extract a concern, or a service object"], hints

    FileUtils.rm_f(Dir[File.join(@dir, "app/services/*.rb")])
    assert_equal ["2 copies in 2 classes; extract a concern"], check.findings.map(&:hint)

    write("app/models/journal.rb", "class Ledger\n  def record(entries)\n    return if entries.empty?\n\n" \
                                   "    notify(entries.size)\n#{POSTING}  end\nend\n")
    assert_equal ["extract a method"], check.findings.map(&:hint)

    git("checkout", "-q", "-b", "feature")
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    write("contract/billing/README.md", "# Billing\n\n```covers\nInvoice\n```\n")
    hint = check.findings.find { |f| f.kind == :method }.hint
    assert_equal "promote one copy to a shared primitive before merge; it belongs to the billing primitive", hint
  end

  # Value: protects=ERB hints point at an existing partial when one is the match, and at extraction otherwise; fails_when=a copied partial isn't named, or a template copy gets a Ruby hint; why_new=ERB hints had no test; seam=none
  # Contract: gate/G11
  def test_erb_hints_follow_fixed_rules
    markup = <<~ERB
      <div class="totals">
        <% @order.lines.each do |line| %>
          <span class="name"><%= line.name %></span>
          <span class="amount"><%= number_to_currency(line.amount) %></span>
        <% end %>
        <strong><%= number_to_currency(@order.total) %></strong>
      </div>
    ERB
    write("app/views/orders/_totals.html.erb", markup)
    commit("partial")
    git("checkout", "-q", "-b", "feature")
    write("app/views/invoices/show.html.erb", markup)

    assert_equal "render the existing partial views/orders/_totals.html.erb", check.findings.fetch(0).hint

    commit("a copy of the partial")
    git("mv", "app/views/orders/_totals.html.erb", "app/views/orders/summary.html.erb")
    commit("the partial becomes a page")
    assert_equal "extract a partial or a component", check.findings.fetch(0).hint
  end

  # Value: protects=gate time stays close to linear in the copies of one finding; fails_when=scoring or clustering goes quadratic, as at 7622907 where 800 copies took 38s; why_new=review timed the blowup; seam=a plain directory, so no blame or base sweep adds time
  # Contract: gate/G12
  def test_eight_hundred_identical_methods_are_one_finding_in_linear_time
    plain = Dir.mktmpdir("exhale-scale")
    body = "    record = find(params[:id])\n    record.destroy!\n    audit(record, :destroyed)\n" \
           "    flash[:notice] = t(\".destroyed\", name: record.name)\n    redirect_to index_path, status: :see_other\n" \
           "    record\n"
    800.times do |n|
      File.write(File.join(plain, format("c%03d.rb", n)), "class C#{n}\n  def destroy\n#{body}  end\nend\n")
    end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = check(root: plain)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal 1, result.findings.size
    assert_equal 799, result.findings.fetch(0).others.size
    assert_operator elapsed, :<, 15, "800 copies took #{elapsed.round(1)}s"
  ensure
    FileUtils.rm_rf(plain)
  end

  # A close copy of RECEIPT: one extra statement keeps its score under 1
  # and over 0.8, so it matches at the default threshold.
  CLOSE_RECEIPT = RECEIPT.sub("    off = items", "    notify(net)\n    off = items")

  # Value: protects=with no merge base the run says so, labels nothing, and flags no clause as new; fails_when=the note drops out, or every kept pair reads as a new clause because there is no base to compare with; why_new=every kept-pair test had a base; seam=none
  # Contract: clause/C3
  def test_with_no_merge_base_findings_are_unlabeled_and_no_clause_is_new
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    shipment = "class Shipment\n  def label(parcel)\n    code = parcel.carrier.code\n    number = parcel.tracking_number\n" \
               "    weight = parcel.weight.round(2)\n    [code, number, weight].join(\"-\")\n  end\nend\n"
    write("app/models/shipment.rb", shipment)
    write("app/models/parcel.rb", shipment.sub("class Shipment", "class Parcel"))
    write("contract/billing/duplication.md", "## Kept\n\n```parallel\nInvoice\nReceipt\n```\n")
    commit("all on a branch no default ref names")
    git("branch", "-q", "-m", "trunk")

    result = Exhale::Dry::Check.new(root: @dir, cache_dir: File.join(@dir, "tmp", "exhale")).run

    assert_nil result.base_sha
    assert_includes result.notes, "no merge base found, so findings are unlabeled"
    assert_equal [false], result.kept.map(&:new_clause)
    assert_equal [:found], result.findings.map(&:klass)
  end

  # Value: protects=a touched location is the copy even when blame can't tell it from the original; fails_when=a touched copy committed in the same second as the original loses to path order; why_new=every touched copy also sorted last by path; seam=none
  # Contract: gate/G9
  def test_a_touched_location_is_the_copy_whatever_its_commit_time
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/aaa_receipt.rb", RECEIPT)
    commit("a copy, committed in the same second")

    finding = check.findings.fetch(0)

    assert_equal "app/models/aaa_receipt.rb", finding.copy.path
    assert_equal [finding.copy], finding.touched
  end

  # Value: protects=with nothing touched, the copy is the location whose own lines were committed last, read over exactly its lines; fails_when=age reads a line past either end of a unit, so an edit to the class's closing line or a unit's def line moves the copy; why_new=copy selection by age had no test where a unit's first or last line differs from its neighbours; seam=none
  # Contract: gate/G9
  def test_the_copy_is_the_location_whose_own_lines_were_committed_last
    @date = "2026-01-01T00:00:00Z"
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    @date = "2026-01-02T00:00:00Z"
    write("app/models/receipt.rb", RECEIPT)
    commit("receipt")
    # The line after the method, not the method, changes last.
    @date = "2026-01-03T00:00:00Z"
    write("app/models/invoice.rb", INVOICE.sub(/end\n\z/, "end # Invoice\n"))
    commit("comment the class end")

    assert_equal "app/models/receipt.rb", check.findings.fetch(0).copy.path

    # Now the method's own first line changes last.
    @date = "2026-01-04T00:00:00Z"
    write("app/models/invoice.rb", INVOICE.sub(/end\n\z/, "end # Invoice\n").sub("def totals(lines)", "def totals(lines) # one per line"))
    commit("comment the def line")

    assert_equal "app/models/invoice.rb", check.findings.fetch(0).copy.path
  end

  # Value: protects=payoff is the copy's normalized nodes weighted by its score; fails_when=payoff divides by the score, so a near copy pays off more than an exact one; why_new=payoff was only seen at score 1, where weighting and dividing agree; seam=none
  # Contract: gate/G10
  def test_payoff_weighs_a_near_copy_by_its_score
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", CLOSE_RECEIPT)
    commit("a near copy")

    finding = check.findings.fetch(0)

    assert_operator finding.score, :<, 1
    assert_equal (finding.copy.size * finding.score).to_f.round(1), finding.payoff
  end

  # Value: protects=a finding nobody touched is already there when its two shapes matched at the base, even under new names; fails_when=renaming the class around an old copy relabels the pair shifted; why_new=the move test kept every identity; seam=none
  # Contract: gate/G4
  def test_a_renamed_class_around_an_old_copy_is_already_there_by_structure
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT.sub("class Receipt", "class Bill"))

    finding = check.findings.fetch(0)

    assert_equal %w[Bill#totals Invoice#totals], [finding.copy, *finding.others.map(&:first)].map { |l| l.unit.identity }.sort
    assert_empty finding.touched
    assert_equal :already_there, finding.klass
  end

  # Value: protects=a location in the same file at the base and the head keeps its identity, so an edit that leaves it a copy is already there; fails_when=keys stop matching across commits for an unmoved file and the edited old copy reads as introduced; why_new=the identity route needed its own test once keys carried the file; seam=none
  # Contract: gate/G4
  def test_the_same_file_at_base_and_head_keeps_its_identity
    write("app/models/a_invoice.rb", INVOICE)
    write("app/models/b_receipt.rb", RECEIPT)
    commit("an old pair")
    git("checkout", "-q", "-b", "feature")
    write("app/models/b_receipt.rb", RECEIPT.gsub("levy", "duty"))
    commit("edit the receipt")

    finding = check.findings.fetch(0)

    assert_equal ["app/models/b_receipt.rb"], finding.touched.map(&:path)
    refute_equal finding.copy.key, finding.others.fetch(0)[0].key
    assert_equal :already_there, finding.klass
  end

  # Value: protects=an untouched file moved to a new path keeps its old finding through its structure; fails_when=the file-bearing key breaks the pair and a pure move reads as shifted; why_new=moves now change keys, so structure has to carry them; seam=none
  # Contract: gate/G4
  def test_a_moved_file_left_alone_is_vouched_for_by_its_structure
    write("app/models/a_invoice.rb", INVOICE)
    write("app/models/b_receipt.rb", RECEIPT)
    commit("an old pair")
    git("checkout", "-q", "-b", "feature")
    FileUtils.mkdir_p(File.join(@dir, "app/billing"))
    git("mv", "app/models/b_receipt.rb", "app/billing/receipt.rb")
    commit("move the receipt")

    finding = check.findings.fetch(0)

    assert_includes [finding.copy, *finding.others.map(&:first)].map(&:path), "app/billing/receipt.rb"
    assert_empty finding.touched
    assert_equal :already_there, finding.klass
  end

  # Value: protects=a new file defining a unit under an old unit's name is a new location, so its copy is introduced; fails_when=keys hold only the identity and c_invoice.rb's new Invoice#totals inherits a_invoice.rb's base pair as already there; why_new=Codex #9 proved a same-named unit in a new file hid behind the old one; seam=none
  # Contract: gate/G3
  # Contract: gate/G4
  def test_a_same_named_unit_in_a_new_file_is_introduced
    write("app/models/a_invoice.rb", INVOICE)
    write("app/models/b_receipt.rb", RECEIPT)
    commit("an old pair")
    git("checkout", "-q", "-b", "feature")
    write("app/models/c_invoice.rb", INVOICE)
    commit("Invoice#totals again, in another file")

    finding = check.findings.fetch(0)

    assert_equal %w[Invoice#totals Invoice#totals Receipt#totals], identities(finding)
    assert_equal ["app/models/c_invoice.rb"], finding.touched.map(&:path)
    assert_equal :introduced, finding.klass
  end

  # Value: protects=a unit defined under the same name in another file is another location, so an old pair's identity can't vouch for a new one; fails_when=keys hold only the identity and a far copy of Invoice#totals in a second file inherits the deleted file's base pair; why_new=G4 now says a location's identity includes its file; seam=none
  # Contract: gate/G4
  def test_a_same_named_unit_in_another_file_is_another_location
    far = INVOICE.sub("discount = lines.select(&:discounted?).sum(&:discount)", "audit(lines)\n    log(tax)\n    discount = 0")
    write("app/models/a_invoice.rb", INVOICE)
    write("app/models/b_receipt.rb", RECEIPT)
    write("app/models/c_invoice.rb", far)
    commit("Invoice#totals twice, one copy of it")
    git("checkout", "-q", "-b", "feature")
    git("rm", "-q", "app/models/a_invoice.rb")
    write("contract/billing/README.md", "```covers\nInvoice\nReceipt\n```\n")
    write("contract/billing/duplication.md", "```settings\nthreshold: 0.5\n```\n")

    finding = check.findings.fetch(0)

    assert_equal %w[app/models/b_receipt.rb app/models/c_invoice.rb], [finding.copy, *finding.others.map(&:first)].map(&:path).sort
    assert_operator finding.score, :<, Rational(4, 5)
    assert_empty finding.touched
    assert_equal :shifted, finding.klass
  end

  # Value: protects=a base pair that still matches after an edit is not contracted; fails_when=contracted compares only shapes, so editing one side of a near copy lists the pair as contracted while it still matches; why_new=the contracted test only removed a side; seam=none
  # Contract: gate/G5
  def test_a_pair_that_still_matches_after_an_edit_is_not_contracted
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", CLOSE_RECEIPT)
    commit("a near copy")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", CLOSE_RECEIPT.sub("notify(net)", "notify(net, levy)"))

    result = check

    assert_equal 1, result.findings.size
    assert_empty result.contracted
  end

  # Value: protects=a finding lists its other sides best match first, so its score and hint come from the closest copy; fails_when=the other sides come in discovery order and a near copy found first sets the finding's score and hint; why_new=multi-copy findings only had exact copies, whose scores tie; seam=none
  # Contract: gate/G10
  def test_other_sides_are_listed_best_match_first
    write("app/models/aaa_near.rb", CLOSE_RECEIPT.sub("class Receipt", "class Near"))
    write("app/models/invoice.rb", INVOICE)
    commit("an original and a near copy")
    git("checkout", "-q", "-b", "feature")
    write("app/models/zzz_copy.rb", INVOICE.sub("class Invoice", "class Copy"))

    finding = check.findings.fetch(0)
    scores = finding.others.map(&:last)

    assert_equal "app/models/zzz_copy.rb", finding.copy.path
    assert_equal scores.sort.reverse, scores
    assert_operator scores.last, :<, 1
    assert_equal 1, finding.score
    assert_equal "extend or call Invoice#totals", finding.hint
  end

  # Value: protects=a clause keeps a group of identical units only when it keeps every pair, the ones the star skips included; fails_when=only the star's edges are judged, so B#run and B#other, both under reference B, pass as kept; why_new=Codex #1 proved the star made keeping unsound and the run exited 0; seam=none
  # Contract: gate/G8
  def test_a_clause_keeps_identical_units_only_when_it_keeps_every_pair
    write("app/models/a.rb", identical("A", "run"))
    write("app/models/b.rb", identical("B", "run", "other"))
    write("contract/billing/duplication.md", "## A and B stay apart\n\n```parallel\nA\nB\n```\n")
    commit("A and B kept, B repeats itself")

    result = check

    assert_equal 1, result.exit_code, Exhale::Report.render(result, "text")
    assert_equal [%w[B#other B#run]], result.findings.map { |f| identities(f) }
    refute_empty result.kept
  end

  # Value: protects=a match two clauses keep from a group's hub doesn't vouch for the group's other members; fails_when=hub-to-hub matches are judged by the hubs alone, so B#totals and X#totals, kept by no clause, never meet; why_new=the star skips every member-to-other-hub pair, not only pairs inside the group; seam=none
  # Contract: gate/G8
  def test_a_kept_match_from_a_hub_does_not_vouch_for_its_twins
    write("app/models/a.rb", identical("A", "totals"))
    write("app/models/b.rb", identical("B", "totals"))
    write("app/models/x.rb", "class X\n  def totals(items)\n" \
                             "    net = items.sum { |item| item.amount * item.quantity }\n" \
                             "    levy = net * rate_for(region)\n    off = items.select(&:discounted?).sum(&:discount)\n" \
                             "    notify(net)\n    { subtotal: net, tax: levy, discount: off, total: net + levy - off }\n" \
                             "  end\nend\n")
    write("contract/billing/duplication.md", "## A and X stay apart\n\n```parallel\nA\nX\n```\n\n" \
                                             "## A and B stay apart\n\n```parallel\nA\nB\n```\n")
    commit("A kept with B and with X, B and X kept with nothing")

    result = check

    assert_equal 1, result.exit_code, Exhale::Report.render(result, "text")
    assert_equal [%w[B#totals X#totals]], result.findings.map { |f| identities(f) }
  end

  # Value: protects=labels follow the base finding, not only the pairs the base matcher emitted; fails_when=deleting the base's hub A and touching B labels the old B-C pair introduced; why_new=Codex #10 proved base pair keys held only star edges; seam=none
  # Contract: gate/G3
  # Contract: gate/G4
  def test_deleting_the_hub_does_not_make_an_old_pair_new
    %w[A B C].each { |name| write("app/models/#{name.downcase}.rb", identical(name, "totals")) }
    commit("three copies")
    git("checkout", "-q", "-b", "feature")
    git("rm", "-q", "app/models/a.rb")
    write("app/models/b.rb", identical("B", "totals").gsub("subtotal", "net")) # touched, still a copy
    commit("drop A, edit B")

    result = check

    finding = result.findings.fetch(0)
    assert_equal %w[B#totals C#totals], identities(finding)
    assert_equal ["B#totals"], finding.touched.map { |l| l.unit.identity }
    assert_equal :already_there, finding.klass
    assert_equal 0, check(introduced_only: true).exit_code
  end

  # Value: protects=an unchanged finding is already there when its locations sat in one base finding, even through a pair under the threshold; fails_when=A~C under 0.80 makes the untouched chain A-B-C read shifted, and the on-ramp fails against its own base; why_new=Codex #10 proved labels compared only the copy and the original; seam=none
  # Contract: gate/G4
  # Contract: gate/G7
  def test_an_unchanged_chain_is_already_there
    write("app/models/a.rb", chain("A", "raise Frozen if frozen?"))
    write("app/models/b.rb", chain("B", "raise Frozen if frozen?", "yield self if block_given?"))
    write("app/models/c.rb", chain("C", "yield self if block_given?"))
    commit("a chain of near copies")
    git("checkout", "-q", "-b", "feature")
    write("README.md", "docs only\n")
    commit("docs")

    result = check

    finding = result.findings.fetch(0)
    assert_equal %w[A#totals B#totals C#totals], identities(finding)
    sweep = Exhale::Dry::Sweep.new(@dir).run
    a, c = %w[A#totals C#totals].map { |id| sweep.index.entries.find { |e| e.unit.identity == id } }
    assert_operator sweep.index.score(a.set, a.total, c.set, c.total), :<, Rational(4, 5), "A and C meet only through B"
    assert_empty finding.touched
    assert_equal :already_there, finding.klass
    assert_equal 0, check(introduced_only: true).exit_code
  end

  # Value: protects=contraction counts occurrences, so deleting one of three identical copies is a contraction; fails_when=the surviving A-B pair shares its structure with the lost A-C pair and hides it; why_new=Codex #11 proved set membership dropped the lost pair; seam=none
  # Contract: gate/G5
  def test_deleting_one_of_three_identical_copies_is_contracted
    %w[A B C].each { |name| write("app/models/#{name.downcase}.rb", identical(name, "totals")) }
    commit("three copies")
    git("checkout", "-q", "-b", "feature")
    git("rm", "-q", "app/models/c.rb")
    commit("drop C")

    result = check

    assert_equal 1, result.contracted.size
    assert_match(/C#totals/, [result.contracted.first.a, result.contracted.first.b].join(" "))
    assert_equal [%w[A#totals B#totals]], result.findings.map { |f| identities(f) }
  end

  # Value: protects=a file exhale can't read as UTF-8 fails the run instead of being skipped; fails_when=an invalid-UTF-8 source file is dropped and the run passes on code it never read; why_new=Codex #4 proved unreadable files passed silently; seam=none
  # Contract: gate/G2
  def test_a_file_that_is_not_utf8_exits_two
    write("app/models/invoice.rb", INVOICE)
    File.binwrite(File.join(@dir, "app/models/latin.rb"), "class Latin\n  def name = \"caf\xE9\"\nend\n".b)
    commit("a latin-1 file")

    result = check

    assert_equal 2, result.exit_code
    assert_equal ["app/models/latin.rb"], result.parse_errors.map(&:path)
  end

  # Value: protects=the unreadable-file error names the line holding the first invalid byte; fails_when=the line is off by one, so the author is sent to the wrong line; why_new=the UTF-8 test only checked the path; seam=none
  # Contract: gate/G2
  def test_a_file_that_is_not_utf8_names_the_line_of_the_bad_byte
    write("app/models/invoice.rb", INVOICE)
    File.binwrite(File.join(@dir, "app/models/latin.rb"), "class Latin\n  def a = 1\n  def name = \"caf\xE9\"\nend\n".b)
    commit("a latin-1 file")

    error = check.parse_errors.first

    assert_equal 3, error.line
  end

  # Value: protects=a source file exhale can't open fails the run and names the file; fails_when=the read error crashes the check or the file is skipped and the run passes; why_new=Codex #4 proved unreadable files were dropped, and with the filter gone a read error raised out of the sweep; seam=a plain directory, so git never reads the file
  # Contract: gate/G2
  def test_a_file_that_cannot_be_read_exits_two
    skip "root reads every file" if Process.uid.zero?

    plain = Dir.mktmpdir("exhale-unreadable")
    File.write(File.join(plain, "invoice.rb"), INVOICE)
    locked = File.join(plain, "locked.rb")
    File.write(locked, "class Locked\n  def x = 1\nend\n")
    File.chmod(0o000, locked)

    result = check(root: plain)

    assert_equal 2, result.exit_code
    assert_equal ["locked.rb"], result.parse_errors.map(&:path)
  ensure
    File.chmod(0o644, locked) if locked && File.exist?(locked)
    FileUtils.rm_rf(plain) if plain
  end
end
