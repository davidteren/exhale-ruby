# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "set"
require "exhale/git"
require "exhale/dry/check"

# Revision's obligations (contract/revision/README.md): what exhale reads
# from git must not move with the user's git config, odd paths, the object
# format, export attributes or where the app sits in its repository.
class RevisionContractTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("exhale-revision")
    @clock = 1_700_000_000
    @config = File.join(@dir, "global.gitconfig")
    File.write(@config, "")
    @repo = File.join(@dir, "repo")
    FileUtils.mkdir_p(@repo)
    # Exhale shells out with the process environment, so every git it runs
    # here reads this file as the user's global config and no system config.
    @saved_env = ENV.to_h.slice(*ISOLATION)
    ENV["GIT_CONFIG_GLOBAL"] = @config
    ENV["GIT_CONFIG_NOSYSTEM"] = "1"
  end

  def teardown
    ISOLATION.each { |key| @saved_env.key?(key) ? ENV[key] = @saved_env[key] : ENV.delete(key) }
    FileUtils.remove_entry(@dir)
  end

  ISOLATION = %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].freeze

  def init(*args)
    sh("init", "-q", "-b", "main", *args)
    sh("config", "user.name", "T")
    sh("config", "user.email", "t@example.com")
    sh("config", "commit.gpgsign", "false")
  end

  def sh(*args, chdir: @repo)
    out, err, st = Open3.capture3(env, "git", "-C", chdir, *args)
    raise "git #{args.join(' ')}: #{err}" unless st.success?

    out.strip
  end

  def env
    date = "#{@clock} +0000"
    { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date, "GIT_CONFIG_GLOBAL" => @config,
      "GIT_CONFIG_NOSYSTEM" => "1" }
  end

  # The user's global config, for the length of the block.
  def with_global_config(lines)
    File.write(@config, lines.join("\n") + "\n")
    yield
  ensure
    File.write(@config, "")
  end

  def write(path, content, root: @repo)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(msg)
    @clock += 1000
    sh("add", "-A")
    sh("commit", "-q", "-m", msg)
    sh("rev-parse", "HEAD")
  end

  def numbered(count, prefix = "line")
    (1..count).map { |i| "#{prefix} #{i}\n" }.join
  end

  def edit_line(path, number, text, root: @repo)
    full = File.join(root, path)
    lines = File.readlines(full)
    lines[number - 1] = "#{text}\n"
    File.write(full, lines.join)
  end

  ODD_PATHS = ["app/with space/a b.rb", "app/café.rb", "app/say \"hi\".rb", "b/nested.rb", "c/w.rb"].freeze

  def odd_paths_changed
    init
    ODD_PATHS.each { |path| write(path, numbered(6)) }
    base = commit("base")
    ODD_PATHS.each { |path| edit_line(path, 3, "edited") }
    base
  end

  # At 7622907 a path with a space came back with git's trailing tab, a
  # quoted path came back with its quotes, and the user's diff prefixes
  # leaked into the keys.
  # Contract: revision/V1
  def test_paths_with_spaces_and_special_characters_are_read_as_written
    base = odd_paths_changed

    expected = ODD_PATHS.to_h { |path| [path, Set[3]] }
    assert_equal expected, with_global_config([]) { Exhale::Git.new(@repo).changed_lines(base) }
  end

  # Contract: revision/V1
  def test_touched_lines_ignore_mnemonic_prefix
    base = odd_paths_changed
    plain = with_global_config([]) { Exhale::Git.new(@repo).changed_lines(base) }

    mnemonic = with_global_config(["[diff]", "\tmnemonicPrefix = true"]) { Exhale::Git.new(@repo).changed_lines(base) }

    assert_equal plain, mnemonic
    assert_equal ODD_PATHS.sort, mnemonic.keys.sort
  end

  # Contract: revision/V1
  def test_touched_lines_ignore_noprefix
    base = odd_paths_changed
    plain = with_global_config([]) { Exhale::Git.new(@repo).changed_lines(base) }

    bare = with_global_config(["[diff]", "\tnoprefix = true"]) { Exhale::Git.new(@repo).changed_lines(base) }

    assert_equal plain, bare
    assert_equal ODD_PATHS.sort, bare.keys.sort
  end

  # Contract: revision/V1
  def test_touched_lines_ignore_the_users_diff_algorithm_and_relative_settings
    base = odd_paths_changed
    plain = with_global_config([]) { Exhale::Git.new(@repo).changed_lines(base) }

    tuned = with_global_config(["[diff]", "\talgorithm = patience", "\trelative = true", "\tindentHeuristic = true",
                                "\trenames = false"]) { Exhale::Git.new(@repo).changed_lines(base) }

    assert_equal plain, tuned
  end

  # An added line reading "++ b/evil.rb" shows up in the diff as
  # "+++ b/evil.rb". At 7622907 it was read as a file header, and the next
  # hunk was credited to a file that doesn't exist.
  # Contract: revision/V1
  def test_an_added_line_that_looks_like_a_file_header_is_content
    init
    write("app/a.rb", numbered(10))
    base = commit("base")
    edit_line("app/a.rb", 2, "++ b/evil.rb")
    edit_line("app/a.rb", 8, "edited")

    changed = with_global_config([]) { Exhale::Git.new(@repo).changed_lines(base) }

    assert_equal({ "app/a.rb" => Set[2, 8] }, changed)
  end

  # Contract: revision/V1
  def test_touched_lines_are_what_the_working_tree_adds_or_changes
    init
    write("app/a.rb", numbered(10))
    write("app/gone.rb", numbered(3))
    base = commit("base")
    sh("checkout", "-q", "-b", "feature")
    edit_line("app/a.rb", 4, "committed edit")
    commit("feature")
    edit_line("app/a.rb", 7, "uncommitted edit")
    File.delete(File.join(@repo, "app/gone.rb"))
    write("app/new.rb", numbered(2))

    changed = with_global_config([]) { Exhale::Git.new(@repo).changed_lines(base) }

    assert_equal({ "app/a.rb" => Set[4, 7], "app/new.rb" => Set[1, 2] }, changed)
  end

  # At 7622907 the base came from git archive, which drops export-ignore
  # paths and rewrites export-subst placeholders.
  # Contract: revision/V2
  def test_export_attributes_do_not_change_the_base_tree
    init
    subst = "# Built from $Format:%H$\nclass Version; end\n"
    write(".gitattributes", "app/legacy/** export-ignore\napp/version.rb export-subst\n")
    write("app/legacy/receipt.rb", "class Receipt; end\n")
    write("app/version.rb", subst)
    write("app/models/invoice.rb", "class Invoice; end\n")
    base = commit("base")
    git = Exhale::Git.new(@repo)
    out = File.join(@dir, "export")

    files = git.files_at(base)
    git.export_files(base, files, out)

    assert_includes files, "app/legacy/receipt.rb"
    assert_equal "class Receipt; end\n", File.binread(File.join(out, "app/legacy/receipt.rb"))
    assert_equal subst, File.binread(File.join(out, "app/version.rb"))
    files.each { |path| assert_equal sh("cat-file", "blob", "#{base}:#{path}"), File.binread(File.join(out, path)).strip }
  end

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

  # The same through the whole check, so it runs at any commit: a pair
  # already on main, one side under an export-ignore directory. Read from a
  # git archive, the base loses that side and the pair reads as shifted.
  # Contract: revision/V2
  def test_a_duplicate_under_export_ignore_is_already_there_at_the_base
    init
    write(".gitignore", "tmp/\n")
    write(".gitattributes", "app/legacy/** export-ignore\n")
    write("app/models/invoice.rb", INVOICE)
    write("app/legacy/receipt.rb", INVOICE.sub("class Invoice", "class Receipt"))
    commit("both")
    sh("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", "class Shipment\n  def label\n    code\n  end\nend\n")

    result = Exhale::Dry::Check.new(root: @repo, base: "main", cache_dir: File.join(@dir, "cache")).run

    assert_equal [:already_there], result.findings.map(&:klass)
  end

  # Contract: revision/V2
  def test_the_base_tree_is_raw_blobs_whatever_the_filters
    init
    write(".gitattributes", "*.rb text eol=crlf\n")
    write("app/a.rb", "x = 1\ny = 2\n")
    base = commit("base")
    out = File.join(@dir, "export")

    with_global_config(["[core]", "\tautocrlf = true"]) { Exhale::Git.new(@repo).export_files(base, ["app/a.rb"], out) }

    assert_equal "x = 1\ny = 2\n", File.binread(File.join(out, "app/a.rb"))
  end

  # Symlinks (mode 120000) aren't source: neither the head file list nor
  # the base tree lists them.
  def test_symlinks_are_not_listed_at_the_head_or_the_base
    init
    write("app/real.rb", "x = 1\n")
    File.symlink("real.rb", File.join(@repo, "app/link.rb"))
    base = commit("base")
    git = Exhale::Git.new(@repo)

    assert_equal ["app/real.rb"], git.files
    assert_equal ["app/real.rb"], git.files_at(base)
  end

  def blame_fixture
    write("app/a.rb", "one\ntwo\nthree\n")
    commit("first")
    first = @clock
    write("app/a.rb", "one\nTWO\nthree\n")
    commit("second")
    second = @clock
    [first, second]
  end

  # At 7622907 the blame parser only knew 40-character SHA-1 headers, so in
  # a SHA-256 repository a NoMethodError escaped from blame_times.
  # Contract: revision/V3
  def test_line_ages_work_in_a_sha256_repository
    init("--object-format=sha256")
    first, second = blame_fixture
    write("app/a.rb", "one\nTWO\nthree\nfour\n")
    git = Exhale::Git.new(@repo)

    assert_equal 64, git.head_sha.size
    assert_equal [first, second, first, Float::INFINITY], git.blame_times("app/a.rb")
    assert_equal second, git.blame_time("app/a.rb", 1, 3)
    assert_equal Float::INFINITY, git.blame_time("app/a.rb", 3, 4)
  end

  # Contract: revision/V3
  def test_line_ages_work_in_a_sha1_repository
    init
    first, second = blame_fixture
    write("app/a.rb", "one\nTWO\nthree\nfour\n")
    git = Exhale::Git.new(@repo)

    assert_equal 40, git.head_sha.size
    assert_equal [first, second, first, Float::INFINITY], git.blame_times("app/a.rb")
    assert_equal Float::INFINITY, git.blame_time("app/a.rb", 4, 4)
  end

  # A repo-local ignore-revs file would blame line 2 on the first commit.
  # Contract: revision/V3
  def test_line_ages_ignore_the_repositorys_ignore_revs_settings
    init
    first, second = blame_fixture
    File.write(File.join(@repo, ".git-blame-ignore-revs"), "#{sh('rev-parse', 'HEAD')}\n")
    sh("config", "blame.ignoreRevsFile", ".git-blame-ignore-revs")
    sh("config", "blame.markIgnoredLines", "true")
    git = Exhale::Git.new(@repo)

    assert_equal [first, second, first], git.blame_times("app/a.rb")
    assert_equal second, git.blame_time("app/a.rb", 2, 2)
  end

  # Contract: revision/V3
  def test_uncommitted_lines_are_newer_than_anything_committed
    init
    blame_fixture
    write("app/a.rb", "one\nTWO\nedited\n")
    write("app/untracked.rb", "x\ny\n")
    git = Exhale::Git.new(@repo)

    times = git.blame_times("app/a.rb")
    assert_equal Float::INFINITY, times[2]
    assert_operator times[2], :>, times[0..1].max
    assert_equal [Float::INFINITY, Float::INFINITY], git.blame_times("app/untracked.rb")
  end

  # An app in agora/ of a bigger repository: everything is scoped to agora/
  # and keyed relative to it.
  def monorepo
    init
    @app = File.join(@repo, "agora")
    write("app/models/a.rb", numbered(6), root: @app)
    write("lib/b.rb", numbered(4), root: @app)
    write("other/app/models/a.rb", numbered(6))
    write("README.md", "top\n")
    base = commit("base")
    @base_time = @clock
    edit_line("app/models/a.rb", 2, "edited", root: @app)
    edit_line("other/app/models/a.rb", 5, "edited")
    write("app/models/new.rb", numbered(2), root: @app)
    write("other/new.rb", numbered(2))
    base
  end

  # Contract: revision/V4
  def test_touched_lines_in_a_subdirectory_app_are_scoped_and_relative
    base = monorepo
    git = Exhale::Git.new(@app)

    assert_equal "agora/", git.prefix
    assert_equal({ "app/models/a.rb" => Set[2], "app/models/new.rb" => Set[1, 2] }, git.changed_lines(base))
  end

  # Contract: revision/V4
  def test_file_lists_in_a_subdirectory_app_are_scoped_and_relative
    base = monorepo
    git = Exhale::Git.new(@app)

    assert_equal ["app/models/a.rb", "lib/b.rb"], git.files_at(base)
    assert_equal ["app/models/a.rb", "app/models/new.rb", "lib/b.rb"], git.files
  end

  # Contract: revision/V4
  def test_the_base_export_in_a_subdirectory_app_is_scoped_and_relative
    base = monorepo
    git = Exhale::Git.new(@app)
    out = File.join(@dir, "export")

    git.export_files(base, git.files_at(base), out)

    assert_equal ["app/models/a.rb", "lib/b.rb"], Dir.glob("**/*", base: out).select { |p| File.file?(File.join(out, p)) }.sort
    assert_equal numbered(6), File.read(File.join(out, "app/models/a.rb"))
  end

  # Contract: revision/V4
  def test_blame_in_a_subdirectory_app_reads_paths_relative_to_the_app
    monorepo
    git = Exhale::Git.new(@app)

    times = git.blame_times("app/models/a.rb")
    assert_equal [@base_time, Float::INFINITY, @base_time, @base_time, @base_time, @base_time], times
    assert_equal @base_time, git.blame_time("lib/b.rb", 1, 4)
  end

  # The whole check from agora/: the copy outside the app is never read,
  # paths are relative to the app, and the touched copy is introduced.
  # Contract: revision/V4
  def test_the_check_from_a_subdirectory_app_reads_only_the_app
    init
    app = File.join(@repo, "agora")
    write(".gitignore", "tmp/\n")
    write("app/models/invoice.rb", INVOICE, root: app)
    write("app/models/shipment.rb", "class Shipment\n  def label\n    code\n  end\nend\n", root: app)
    write("other/app/models/receipt.rb", INVOICE.sub("class Invoice", "class Receipt"))
    commit("base")
    sh("checkout", "-q", "-b", "feature")
    write("app/models/quote.rb", INVOICE.sub("class Invoice", "class Quote"), root: app)

    result = Exhale::Dry::Check.new(root: app, base: "main", cache_dir: File.join(@dir, "cache")).run

    assert_equal 1, result.findings.size
    finding = result.findings[0]
    assert_equal :introduced, finding.klass
    assert_equal ["app/models/invoice.rb", "app/models/quote.rb"],
                 ([finding.copy] + finding.others.map(&:first)).map(&:path).sort
  end

  # Codex #14: -U0 alone doesn't stop interHunkContext from merging two
  # hunks, which would count the unchanged lines between them as touched.
  # Contract: revision/V1
  def test_touched_lines_ignore_inter_hunk_context
    init
    write("a.rb", numbered(20))
    base = commit("base")
    edit_line("a.rb", 3, "edited")
    edit_line("a.rb", 9, "edited")

    touched = with_global_config(["[diff]", "\tinterHunkContext = 100"]) { Exhale::Git.new(@repo).changed_lines(base) }

    assert_equal({ "a.rb" => Set[3, 9] }, touched)
  end

  # Codex #15: a newline in a path split cat-file --batch requests in two
  # and shifted every response after it.
  # Contract: revision/V1
  def test_a_path_with_a_newline_exports_and_the_files_after_it_survive
    init
    odd = "app/bad\nname.rb"
    write(odd, "odd = 1\n")
    write("app/z_after.rb", "after = 1\n")
    write("app/a_before.rb", "before = 1\n")
    base = commit("base")
    git = Exhale::Git.new(@repo)
    out = File.join(@dir, "export")

    git.export_files(base, git.files_at(base), out)

    assert_equal ["app/a_before.rb", odd, "app/z_after.rb"].sort, git.files_at(base)
    assert_equal "odd = 1\n", File.read(File.join(out, odd))
    assert_equal "after = 1\n", File.read(File.join(out, "app/z_after.rb"))
    assert_equal "before = 1\n", File.read(File.join(out, "app/a_before.rb"))
  end

  # Codex #12: under a US-ASCII locale, git output was tagged US-ASCII and
  # parsing a non-ASCII path raised.
  # Contract: revision/V1
  def test_git_output_is_read_as_utf8_whatever_the_locale
    init
    write("app/café.rb", numbered(4))
    base = commit("base")
    edit_line("app/café.rb", 2, "edited \u00e9")
    write("app/ünïcode.rb", "x = 1\n")
    git = Exhale::Git.new(@repo)

    with_default_external("US-ASCII") do
      touched = git.changed_lines(base)
      assert_equal ["app/café.rb", "app/ünïcode.rb"], touched.keys.sort
      assert(touched.keys.all? { |k| k.encoding == Encoding::UTF_8 && k.valid_encoding? })
      assert_equal ["app/café.rb"], git.files_at(base)
      assert_includes git.files, "app/café.rb"
    end
  end

  # Codex #5: a sparse checkout hides tracked files, so the head sweep would
  # read less than the commit and call the missing code gone.
  # Contract: gate/G2
  def test_a_sparse_checkout_is_refused_because_it_hides_part_of_the_commit
    init
    write("app/a.rb", "a = 1\n")
    write("other/b.rb", "b = 1\n")
    commit("base")
    git = Exhale::Git.new(@repo)
    refute git.sparse?
    assert_equal ["app/a.rb", "other/b.rb"], git.files

    sh("sparse-checkout", "init", "--cone")
    sh("sparse-checkout", "set", "app")

    assert git.sparse?
    error = assert_raises(Exhale::GitError) { git.files }
    assert_equal "exhale needs the full tree; this checkout is sparse", error.message
  end

  def with_default_external(name)
    saved = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = name
    yield
  ensure
    Encoding.default_external = saved
    $VERBOSE = verbose
  end
end
