# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "stringio"
require "exhale/cli"

# The command line's obligations, contract/cli/README.md, each proved against
# a throwaway git repository with fixed commit dates.
class CLIContractTest < Minitest::Test
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

  # A near copy: one extra statement keeps its score under 1, so the score
  # depends on the fingerprint weights.
  RECEIPT = <<~RUBY
    class Receipt
      def totals(items)
        net = items.sum { |item| item.amount * item.quantity }
        levy = net * rate_for(region)
        off = items.select(&:discounted?).sum(&:discount)
        notify(net)
        { subtotal: net, tax: levy, discount: off, total: net + levy - off }
      end
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-cli-contract")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\nscratch/\n")
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

  def exhale(*args)
    out = StringIO.new
    err = StringIO.new
    code = Exhale::CLI.new([*args, "--root", @dir, "--cache", File.join(@dir, "tmp", "exhale")],
                           out: out, err: err).run
    [code, out.string, err.string]
  end

  # Value: protects=explain scores a pair with the gate's file list and weights, so tuning reads what CI reads; fails_when=explain walks the directory and a gitignored file shifts the fingerprint weights; why_new=review proved explain said 0.78 where the gate said 0.83; seam=none
  # Contract: cli/L1
  def test_explain_scores_a_pair_exactly_as_the_gate_does
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    # Thirty gitignored copies make the shared fingerprints common, which
    # would cut their weight if anything read them.
    write("scratch/copies.rb", (1..30).map { |n| INVOICE.sub("class Invoice", "class Scratch#{n}") }.join("\n"))
    commit("a near copy")

    code, out, err = exhale("dry", "--format", "json")
    assert_equal 1, code, err
    gate = JSON.parse(out)["findings"].fetch(0)
    assert_equal %w[Invoice#totals Receipt#totals], [gate["copy"], *gate["existing"]].map { |l| l["identity"] }.sort

    code, out, err = exhale("dry", "explain", "Invoice#totals", "Receipt#totals")
    assert_equal 0, code, err
    explained = out[/^score ([\d.]+),/, 1]

    assert_equal format("%.2f", gate["score"]), format("%.2f", Float(explained))
  end

  # Value: protects=a --base that names no commit fails instead of running unlabeled; fails_when=a mistyped base is ignored and the run passes or fails on labels nobody asked for; why_new=review proved --base nope was silently ignored; seam=none
  # Contract: cli/L3
  def test_a_base_that_names_no_commit_exits_two
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")

    code, out, err = exhale("--base", "nope")

    assert_equal 2, code
    assert_empty out
    assert_match(/exhale: --base nope names no commit/, err)
  end

  # Value: protects=outside a git repository a --base exits 2, and a run without one goes ahead unlabeled; fails_when=--base is ignored outside git and the run passes on labels nobody can compute, or a run without --base refuses to run; why_new=review proved --base outside a repository was silently dropped; seam=none
  # Contract: cli/L3
  def test_a_base_outside_a_git_repository_exits_two
    Dir.mktmpdir("exhale-no-git") do |dir|
      FileUtils.mkdir_p(File.join(dir, "app", "models"))
      File.write(File.join(dir, "app", "models", "invoice.rb"), INVOICE)
      File.write(File.join(dir, "app", "models", "receipt.rb"), RECEIPT)
      run = lambda do |*args|
        out = StringIO.new
        err = StringIO.new
        code = Exhale::CLI.new([*args, "--root", dir, "--cache", File.join(dir, "tmp")], out: out, err: err).run
        [code, out.string, err.string]
      end

      code, out, err = run.call("--base", "main")
      assert_equal 2, code
      assert_empty out
      assert_equal "exhale: --base main needs a git repository, and #{File.expand_path(dir)} isn't in one\n", err

      code, out, err = run.call
      assert_equal 1, code, err
      assert_match(/\Aexhale dry: 1 found\n/, out)
      assert_match(/^note: no merge base found, so findings are unlabeled$/, out)
    end
  end

  # Value: protects=a --root that doesn't exist, or is a file, exits 2; fails_when=the run sweeps nothing and prints clean; why_new=Codex #6 proved a missing root printed clean and exited 0; seam=none
  # Contract: gate/G2
  def test_a_root_that_is_not_a_directory_exits_two
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    missing = File.join(@dir, "nope")
    file = File.join(@dir, "app/models/invoice.rb")

    [missing, file].each do |root|
      out = StringIO.new
      err = StringIO.new
      code = Exhale::CLI.new(["--root", root], out: out, err: err).run
      assert_equal 2, code, "--root #{root}"
      assert_empty out.string
      assert_match(/exhale: --root #{Regexp.escape(root)} isn't a directory/, err.string)
    end
  end

  # Value: protects=a --base that reads as a git option never reaches git; fails_when=--base --octopus is handed to git merge-base, resolves to HEAD, and the run labels against itself; why_new=Codex #19 proved --base --octopus resolved to HEAD; seam=none
  # Contract: cli/L3
  def test_a_base_that_looks_like_an_option_exits_two
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")

    code, out, err = exhale("--base", "--octopus")

    assert_equal 2, code
    assert_empty out
    assert_match(/exhale: --base --octopus/, err)
  end

  # Value: protects=explain checks --format and --base the way a run does; fails_when=explain prints a score and exits 0 with a format or base nobody can use; why_new=Codex #19 proved explain exited 0 with --format yaml and a bad --base; seam=none
  # Contract: cli/L3
  def test_explain_rejects_an_unknown_format_or_base
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("a near copy")
    pair = %w[dry explain Invoice#totals Receipt#totals]

    assert_equal 0, exhale(*pair).first

    code, out, err = exhale(*pair, "--format", "yaml")
    assert_equal 2, code
    assert_empty out
    assert_match(/unknown format "yaml"/, err)

    [%w[--base nope], %w[--base --octopus]].each do |base|
      code, out, err = exhale(*pair, *base)
      assert_equal 2, code, base.join(" ")
      assert_empty out
      assert_match(/exhale: --base #{Regexp.escape(base.last)}/, err)
    end
  end
end
