# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "exhale/git"

class GitTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("exhale-git")
    @clock = 1_700_000_000
    sh("init", "-q", "-b", "main")
    sh("config", "user.name", "T")
    sh("config", "user.email", "t@example.com")
    sh("config", "commit.gpgsign", "false")
    @git = Exhale::Git.new(@dir)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def sh(*args)
    out, err, st = Open3.capture3(env, "git", "-C", @dir, *args)
    raise "git #{args.join(' ')}: #{err}" unless st.success?

    out.strip
  end

  def env
    date = "#{@clock} +0000"
    { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date }
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(msg)
    @clock += 1000
    sh("add", "-A")
    sh("commit", "-q", "-m", msg)
    sh("rev-parse", "HEAD")
  end

  def test_repo_and_head
    assert @git.repo?
    assert_nil @git.head_sha
    write("a.rb", "x = 1\n")
    sha = commit("one")
    assert_equal sha, @git.head_sha
    refute Exhale::Git.new(Dir.tmpdir).repo? if !File.exist?(File.join(Dir.tmpdir, ".git"))
  end

  def test_merge_base_with_branch
    write("a.rb", "x = 1\n")
    base = commit("base")
    sh("checkout", "-q", "-b", "feature")
    write("b.rb", "y = 1\n")
    commit("feature")
    assert_equal base, @git.merge_base("main")
  end

  def test_merge_base_missing_ref
    write("a.rb", "x = 1\n")
    commit("base")
    assert_nil @git.merge_base("nope")
    assert_nil @git.merge_base(nil)
  end

  def test_default_branch_ref_fallbacks
    assert_nil @git.default_branch_ref
    write("a.rb", "x = 1\n")
    commit("base")
    assert_equal "main", @git.default_branch_ref
    sh("update-ref", "refs/remotes/origin/master", "HEAD")
    assert_equal "origin/master", @git.default_branch_ref
    sh("update-ref", "refs/remotes/origin/main", "HEAD")
    assert_equal "origin/main", @git.default_branch_ref
  end

  def test_default_branch_ref_from_origin_head
    write("a.rb", "x = 1\n")
    commit("base")
    sh("update-ref", "refs/remotes/origin/trunk", "HEAD")
    sh("update-ref", "refs/remotes/origin/main", "HEAD")
    sh("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/trunk")
    assert_equal "origin/trunk", @git.default_branch_ref
  end

  # Value: protects=an origin/HEAD that points at a branch that no longer exists falls back to the local candidates; fails_when=the dangling ref is returned and the merge base lookup fails on it; why_new=origin/HEAD was only tested pointing at a live branch; seam=none
  def test_default_branch_ref_skips_a_dangling_origin_head
    write("a.rb", "x = 1\n")
    commit("base")
    sh("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/gone")

    assert_equal "main", @git.default_branch_ref
  end

  # Value: protects=the base export writes every blob byte for byte when an earlier blob holds multibyte UTF-8; fails_when=the batch output is read as text, so byte offsets drift as characters and later files get the wrong bytes; why_new=every export test used ASCII files; seam=none
  # Contract: revision/V2
  def test_export_files_writes_blobs_after_multibyte_ones_byte_for_byte
    files = { "a.rb" => "naïve = \"à côté\"\n", "b.rb" => "y = 2\n", "lib/c.rb" => "z = \"ünïcödé\"\nw = 4\n" }
    files.each { |path, content| write(path, content) }
    sha = commit("base")
    out = File.join(@dir, "tmp-export")

    @git.export_files(sha, files.keys, out)

    files.each { |path, content| assert_equal content.b, File.binread(File.join(out, path)), path }
  end

  def test_files_excludes_ignored_and_deleted
    write(".gitignore", "ignored.rb\n")
    write("keep.rb", "a\n")
    write("gone.rb", "a\n")
    commit("base")
    File.delete(File.join(@dir, "gone.rb"))
    write("ignored.rb", "a\n")
    write("new/untracked.rb", "a\n")
    assert_equal [".gitignore", "keep.rb", "new/untracked.rb"], @git.files
  end

  def test_files_at_and_export
    write("a.rb", "x = 1\n")
    write("lib/b.rb", "y = 2\n")
    sha = commit("base")
    write("a.rb", "changed\n")
    commit("two")
    assert_equal ["a.rb", "lib/b.rb"], @git.files_at(sha)
    out = File.join(@dir, "..", "exhale-export-#{Process.pid}")
    begin
      assert_equal out, @git.export(sha, out)
      assert_equal "x = 1\n", File.read(File.join(out, "a.rb"))
      assert_equal "y = 2\n", File.read(File.join(out, "lib/b.rb"))
    ensure
      FileUtils.rm_rf(out)
    end
  end

  # Value: protects=only a work tree counts as a repository; fails_when=a successful rev-parse that answers "false" (inside .git) reads as a repository; why_new=repo? was only tested inside and outside a repository; seam=none
  def test_inside_the_git_dir_is_not_a_repo
    refute Exhale::Git.new(File.join(@dir, ".git")).repo?
  end

  # Value: protects=an untracked path that isn't a file adds no touched lines; fails_when=changed_lines counts the lines of a symlinked directory and crashes reading it; why_new=untracked files in the diff tests were all plain files; seam=none
  def test_an_untracked_symlink_to_a_directory_adds_no_lines
    write("a.rb", "x = 1\n")
    sha = commit("base")
    FileUtils.mkdir_p(File.join(@dir, "elsewhere"))
    write("elsewhere/b.rb", "y = 2\n")
    sh("add", "elsewhere")
    File.symlink(File.join(@dir, "elsewhere"), File.join(@dir, "linked"))

    refute_includes @git.changed_lines(sha).keys, "linked"
  end

  # Value: protects=export_files always leaves its directory in place, even with nothing to write; fails_when=an empty file list returns a directory that doesn't exist; why_new=export_files was only tested with files; seam=none
  def test_export_files_with_no_files_still_makes_the_directory
    write("a.rb", "x = 1\n")
    sha = commit("base")
    out = File.join(@dir, "tmp-export")

    assert_equal out, @git.export_files(sha, [], out)
    assert Dir.exist?(out)
  end

  # Value: protects=a path missing at the commit is skipped and the blobs after it still land byte for byte; fails_when=a missing path is written as an empty file and shifts every later blob; why_new=export_files was only tested with paths that exist; seam=none
  def test_export_files_skips_a_path_missing_at_the_commit
    write("a.rb", "x = 1\n")
    write("b.rb", "y = 2\n")
    sha = commit("base")
    out = File.join(@dir, "tmp-export")

    @git.export_files(sha, ["a.rb", "gone.rb", "b.rb"], out)

    refute File.exist?(File.join(out, "gone.rb"))
    assert_equal ["x = 1\n", "y = 2\n"], %w[a.rb b.rb].map { |path| File.read(File.join(out, path)) }
  end

  # Value: protects=a checkout is sparse when core.sparseCheckout says true and not when it says false; fails_when=the config value is ignored or read as success alone; why_new=the sparse test only covered a real cone checkout; seam=none
  # Contract: source/S6
  def test_sparse_follows_the_config_value
    write("a.rb", "x = 1\n")
    commit("base")
    refute @git.sparse?
    sh("config", "core.sparseCheckout", "false")
    refute @git.sparse?
    sh("config", "core.sparseCheckout", "true")
    assert @git.sparse?
  end

  # Value: protects=a failing cat-file raises GitError naming cat-file; fails_when=the failure is ignored and the empty output is parsed as blobs; why_new=the only cat-file failure test failed in ls-tree first; seam=the repository disappears between the tree read and the blob read
  # Contract: revision/V2
  def test_export_files_raises_when_cat_file_fails
    write("a.rb", "x = 1\n")
    sha = commit("base")
    dir = @dir
    @git.define_singleton_method(:blob_oids) do |at|
      super(at).tap { FileUtils.mv(File.join(dir, ".git"), File.join(dir, "moved.git")) }
    end

    error = assert_raises(Exhale::GitError) { @git.export_files(sha, ["a.rb"], File.join(@dir, "tmp-export")) }
    assert_match(/\Agit cat-file failed/, error.message)
  end

  # Value: protects=a blob the tree lists but the object store lacks is skipped and later blobs still land byte for byte; fails_when=the missing header is read as a size and every later blob shifts; why_new=the missing-path test filtered paths before cat-file ran; seam=a loose object deleted after the commit
  # Contract: revision/V2
  def test_export_files_skips_a_blob_the_object_store_lacks
    write("a.rb", "x = 1\n")
    write("b.rb", "y = 2\n")
    write("c.rb", "z = 3\n")
    sha = commit("base")
    blob = sh("rev-parse", "#{sha}:b.rb")
    object = File.join(@dir, ".git", "objects", blob[0, 2], blob[2..])
    File.chmod(0o644, object)
    File.delete(object)
    out = File.join(@dir, "tmp-export")

    @git.export_files(sha, %w[a.rb b.rb c.rb], out)

    refute File.exist?(File.join(out, "b.rb"))
    assert_equal ["x = 1\n", "z = 3\n"], %w[a.rb c.rb].map { |path| File.read(File.join(out, path)) }
  end

  # Value: protects=a failing git command raises GitError instead of returning its empty output; fails_when=ls-tree, blame or cat-file fails and exhale reads the empty output as an empty tree, no blame or no blobs; why_new=only export (git archive) had a failure test; seam=none
  def test_failing_git_commands_raise
    write("a.rb", "x = 1\n")
    sh("add", "-A")
    # Staged but never committed: blame has no HEAD to read.
    assert_raises(Exhale::GitError) { @git.blame_times("a.rb") }
    error = assert_raises(Exhale::GitError) { @git.blame_time("a.rb", 1, 1) }
    assert_match(/\Agit blame failed: .*HEAD/, error.message)

    sha = commit("base")
    assert_raises(Exhale::GitError) { @git.files_at("deadbeef" * 5) }

    # The repository disappears after exhale located it.
    @git.prefix
    @git.toplevel
    FileUtils.mv(File.join(@dir, ".git"), File.join(@dir, "moved.git"))
    error = assert_raises(Exhale::GitError) { @git.export_files(sha, ["a.rb"], File.join(@dir, "tmp-export")) }
    assert_match(/\Agit (ls-tree|cat-file) failed/, error.message)
  end

  def test_export_bad_sha_raises
    write("a.rb", "x\n")
    commit("base")
    assert_raises(Exhale::GitError) { @git.export("deadbeef" * 5, File.join(@dir, "out")) }
  end

  # Contract: revision/V1
  def test_changed_lines_added_modified_deleted
    write("a.rb", (1..10).map { |i| "l#{i}\n" }.join)
    base = commit("base")
    lines = File.readlines(File.join(@dir, "a.rb"))
    lines[1] = "changed2\n"           # modify line 2
    lines.delete_at(4)                # delete old line 5
    lines.push("added\n")             # append
    File.write(File.join(@dir, "a.rb"), lines.join)
    changed = @git.changed_lines(base)
    assert_equal({ "a.rb" => Set[2, 10] }, changed)
  end

  # Contract: revision/V1
  def test_changed_lines_pure_deletion_has_no_lines
    write("a.rb", "1\n2\n3\n")
    base = commit("base")
    write("a.rb", "1\n3\n")
    assert_equal({}, @git.changed_lines(base))
  end

  # Contract: revision/V1
  def test_changed_lines_untracked_and_deleted_files
    write("a.rb", "1\n")
    write("gone.rb", "1\n")
    base = commit("base")
    File.delete(File.join(@dir, "gone.rb"))
    write("new.rb", "a\nb\nc\n")
    assert_equal({ "new.rb" => Set[1, 2, 3] }, @git.changed_lines(base))
  end

  # Contract: revision/V1
  def test_changed_lines_rename
    body = (1..8).map { |i| "line #{i}\n" }.join
    write("old.rb", body)
    base = commit("base")
    sh("mv", "old.rb", "new.rb")
    write("new.rb", body.sub("line 4\n", "line four\n"))
    assert_equal({ "new.rb" => Set[4] }, @git.changed_lines(base))
  end

  def test_blame_time_ordering
    write("a.rb", "old\nold\n")
    commit("first")
    first_time = @clock
    write("a.rb", "old\nnew\n")
    commit("second")
    second_time = @clock
    assert_equal first_time, @git.blame_time("a.rb", 1, 1)
    assert_equal second_time, @git.blame_time("a.rb", 2, 2)
    assert_equal second_time, @git.blame_time("a.rb", 1, 2)
  end

  # Contract: revision/V3
  def test_blame_times_gives_every_line_its_commit_time_from_one_call
    write("a.rb", "old\nold\n")
    commit("first")
    first_time = @clock
    write("a.rb", "old\nnew\n")
    commit("second")
    second_time = @clock
    write("a.rb", "old\nnew\nuncommitted\n")
    write("u.rb", "x\ny\n")

    assert_equal [first_time, second_time, Float::INFINITY], @git.blame_times("a.rb")
    assert_equal [Float::INFINITY, Float::INFINITY], @git.blame_times("u.rb")
  end

  # Contract: revision/V3
  def test_blame_time_uncommitted_is_infinite
    write("a.rb", "old\nold\n")
    commit("first")
    write("a.rb", "old\nedited\n")
    assert_equal Float::INFINITY, @git.blame_time("a.rb", 2, 2)
    refute_equal Float::INFINITY, @git.blame_time("a.rb", 1, 1)
    write("u.rb", "x\n")
    assert_equal Float::INFINITY, @git.blame_time("u.rb", 1, 1)
  end
end
