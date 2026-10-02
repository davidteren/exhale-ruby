# frozen_string_literal: true

require "fileutils"
require "open3"
require "set"
require "tmpdir"
require_relative "errors"

module Exhale
  # Thin, deterministic wrapper over the git CLI. Every call uses argument
  # arrays and ignores the user's quoting config.
  class Git
    BASE_ARGS = ["-c", "core.quotepath=off", "-c", "diff.renames=true"].freeze
    DEFAULT_CANDIDATES = %w[origin/main origin/master main master].freeze
    ZERO_SHA = "0" * 40
    HUNK = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
    end

    def repo?
      out, _err, status = run("rev-parse", "--is-inside-work-tree")
      status.success? && out.strip == "true"
    end

    def head_sha
      out, _err, status = run("rev-parse", "--verify", "--quiet", "HEAD^{commit}")
      status.success? ? out.strip : nil
    end

    def default_branch_ref
      out, _err, status = run("symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
      if status.success? && ref_exists?(out.strip)
        return out.strip
      end

      DEFAULT_CANDIDATES.find { |ref| ref_exists?(ref) }
    end

    def merge_base(ref)
      return nil if ref.nil? || ref.empty?

      out, _err, status = run("merge-base", ref, "HEAD")
      status.success? && !out.strip.empty? ? out.strip : nil
    end

    # Where root sits inside the repository, like "agora/" for an app in a
    # monorepo. Every path exhale reports is relative to root, so exports and
    # diffs are scoped to it too.
    def prefix
      @prefix ||= run!("rev-parse", "--show-prefix").strip
    end

    def toplevel
      @toplevel ||= run!("rev-parse", "--show-toplevel").strip
    end

    def files
      out = run!("ls-files", "--cached", "--others", "--exclude-standard", "-z")
      out.split("\0").reject(&:empty?).uniq.select { |p| File.file?(File.join(root, p)) }.sort
    end

    def files_at(sha)
      run!("ls-tree", "-r", "--name-only", "-z", sha).split("\0").reject(&:empty?).sort
    end

    def export(sha, dir)
      FileUtils.mkdir_p(dir)
      Dir.mktmpdir("exhale-archive") do |tmp|
        archive = File.join(tmp, "tree.tar")
        # From a subdirectory, git archive also narrows to that directory,
        # which breaks the sha:prefix form. The top level sees the whole tree.
        tree = prefix.empty? ? sha : "#{sha}:#{prefix}"
        _out, err, status = Open3.capture3("git", *BASE_ARGS, "-C", toplevel, "archive", "--format=tar", "-o",
                                           archive, tree)
        raise GitError, "git archive failed: #{err.strip}" unless status.success?

        _out, err, status = Open3.capture3("tar", "-x", "-f", archive, "-C", dir)
        raise GitError, "tar failed: #{err.strip}" unless status.success?
      end
      dir
    end

    def changed_lines(base_sha)
      diff = run!("diff", "--relative", "--unified=0", "--no-color", "--no-ext-diff", "--find-renames",
                  base_sha, "--")
      result = parse_diff(diff)
      untracked_files.each { |path| result[path] = all_lines(path) }
      result.reject { |_path, lines| lines.empty? }
    end

    # Committer time for every line of a file, index 0 being line 1, from one
    # blame call. Uncommitted lines, and every line of an untracked file, are
    # Float::INFINITY: newer than anything committed.
    def blame_times(path)
      full = File.join(root, path)
      return Array.new(File.foreach(full).count, Float::INFINITY) unless tracked?(path)

      out, err, status = run("blame", "--porcelain", "--", path)
      raise GitError, "git blame failed: #{err.strip}" unless status.success?

      line_times(out)
    end

    def blame_time(path, start_line, end_line)
      return Float::INFINITY unless tracked?(path)

      out, err, status = run("blame", "--porcelain", "-L", "#{start_line},#{end_line}", "--", path)
      raise GitError, "git blame failed: #{err.strip}" unless status.success?

      newest_time(out)
    end

    private

    def run(*args)
      Open3.capture3("git", *BASE_ARGS, "-C", root, *args)
    end

    def run!(*args)
      out, err, status = run(*args)
      raise GitError, "git #{args.first} failed: #{err.strip}" unless status.success?

      out
    end

    def ref_exists?(ref)
      _out, _err, status = run("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      status.success?
    end

    def tracked?(path)
      _out, _err, status = run("ls-files", "--error-unmatch", "--", path)
      status.success?
    end

    def untracked_files
      run!("ls-files", "--others", "--exclude-standard", "-z").split("\0").reject(&:empty?).sort
    end

    def all_lines(path)
      full = File.join(root, path)
      return Set.new unless File.file?(full)

      count = File.foreach(full).count
      Set.new(1..count)
    end

    def parse_diff(diff)
      result = Hash.new { |h, k| h[k] = Set.new }
      current = nil
      diff.each_line(chomp: true) do |line|
        if line.start_with?("+++ ")
          current = new_path(line)
        elsif current && (m = HUNK.match(line))
          add_hunk(result[current], m[1].to_i, (m[2] || "1").to_i)
        end
      end
      result.to_h
    end

    def new_path(line)
      target = line.delete_prefix("+++ ")
      target == "/dev/null" ? nil : target.delete_prefix("b/")
    end

    def add_hunk(set, start, count)
      count.times { |i| set << start + i }
    end

    # Porcelain names a commit's metadata only the first time the commit
    # appears, so times are remembered per SHA and handed to each line.
    def line_times(porcelain)
      times = {}
      result = []
      sha = nil
      final = nil
      porcelain.each_line(chomp: true) do |line|
        if line.start_with?("\t")
          result[final - 1] = sha == ZERO_SHA ? Float::INFINITY : times.fetch(sha, 0)
        elsif (m = /\A(\h{40}) \d+ (\d+)/.match(line))
          sha = m[1]
          final = m[2].to_i
        elsif line.start_with?("committer-time ")
          times[sha] = line.split(" ", 2).last.to_i
        end
      end
      result
    end

    def newest_time(porcelain)
      return Float::INFINITY if porcelain.match?(/^#{ZERO_SHA} /)

      times = porcelain.each_line.filter_map { |l| l.split(" ", 2).last.to_i if l.start_with?("committer-time ") }
      times.max or raise GitError, "no blame data"
    end
  end
end
