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

  def test_export_bad_sha_raises
    write("a.rb", "x\n")
    commit("base")
    assert_raises(Exhale::GitError) { @git.export("deadbeef" * 5, File.join(@dir, "out")) }
  end

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

  def test_changed_lines_pure_deletion_has_no_lines
    write("a.rb", "1\n2\n3\n")
    base = commit("base")
    write("a.rb", "1\n3\n")
    assert_equal({}, @git.changed_lines(base))
  end

  def test_changed_lines_untracked_and_deleted_files
    write("a.rb", "1\n")
    write("gone.rb", "1\n")
    base = commit("base")
    File.delete(File.join(@dir, "gone.rb"))
    write("new.rb", "a\nb\nc\n")
    assert_equal({ "new.rb" => Set[1, 2, 3] }, @git.changed_lines(base))
  end

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
