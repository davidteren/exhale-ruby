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
    # The user's git config must not change what exhale reads, or the same
    # commit could get different verdicts on different machines. These pin
    # every setting that changes diff or blame output.
    BASE_ARGS = ["-c", "core.quotepath=off", "-c", "diff.renames=true", "-c", "diff.noprefix=false",
                 "-c", "diff.mnemonicPrefix=false", "-c", "diff.relative=false",
                 "-c", "diff.indentHeuristic=false", "-c", "diff.interHunkContext=0", "-c", "blame.ignoreRevsFile=",
                 "-c", "blame.markIgnoredLines=false", "-c", "blame.markUnblamableLines=false"].freeze
    DEFAULT_CANDIDATES = %w[origin/main origin/master main master].freeze
    # A blame header line: the commit, SHA-1 or SHA-256, then the original
    # and final line numbers.
    BLAME_HEADER = /\A(\h{40}(?:\h{24})?) \d+ (\d+)/
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

    # A sparse checkout leaves tracked files out of the work tree, so a sweep of
    # the head would read less than the commit.
    def sparse?
      out, _err, status = run("config", "--bool", "core.sparseCheckout")
      return true if status.success? && out.strip == "true"

      run!("ls-files", "-t", "-z").split("\0").any? { |entry| entry.start_with?("S ") }
    end

    def files
      raise GitError, "exhale needs the full tree; this checkout is sparse" if sparse?

      out = run!("ls-files", "--cached", "--others", "--exclude-standard", "-z")
      out.split("\0").reject(&:empty?).uniq.select do |path|
        full = File.join(root, path)
        File.file?(full) && !File.symlink?(full)
      end.sort
    end

    # Symlinks (mode 120000) and submodules (type commit) aren't source.
    def files_at(sha)
      blob_oids(sha).keys.sort
    end

    # Writes the named files at sha into dir as raw blobs. git archive would
    # apply export-ignore and export-subst, and the base must be the commit
    # exactly as it is.
    def export_files(sha, paths, dir)
      FileUtils.mkdir_p(dir)
      return dir if paths.empty?

      # Blobs are requested by object id: a path with a newline would split a
      # "sha:path" request in two and shift every response after it.
      oids = blob_oids(sha)
      paths = paths.select { |path| oids.key?(path) }
      return dir if paths.empty?

      out, err, status = Open3.capture3("git", *BASE_ARGS, "-C", root, "cat-file", "--batch",
                                        stdin_data: paths.map { |path| "#{oids[path]}\n" }.join, binmode: true)
      raise GitError, "git cat-file failed: #{utf8(err).strip}" unless status.success?

      write_blobs(out, paths, dir)
      dir
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
        raise GitError, "git archive failed: #{utf8(err).strip}" unless status.success?

        _out, err, status = Open3.capture3("tar", "-x", "-f", archive, "-C", dir)
        raise GitError, "tar failed: #{utf8(err).strip}" unless status.success?
      end
      dir
    end

    def changed_lines(base_sha)
      diff = run!("diff", "--relative", "--unified=0", "--no-color", "--no-ext-diff", "--no-textconv",
                  "--find-renames", "--diff-algorithm=myers", "--src-prefix=a/", "--dst-prefix=b/",
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

      # The flag, unlike an empty -c value, really does reset a repository's
      # own blame.ignoreRevsFile.
      out, err, status = run("blame", "--porcelain", "--no-ignore-revs-file", "--", path)
      raise GitError, "git blame failed: #{err.strip}" unless status.success?

      line_times(out)
    end

    def blame_time(path, start_line, end_line)
      return Float::INFINITY unless tracked?(path)

      out, err, status = run("blame", "--porcelain", "--no-ignore-revs-file", "-L", "#{start_line},#{end_line}",
                             "--", path)
      raise GitError, "git blame failed: #{err.strip}" unless status.success?

      newest_time(out)
    end

    private

    # Output is UTF-8 whatever the locale, so no verdict depends on it.
    def run(*args)
      out, err, status = Open3.capture3("git", *BASE_ARGS, "-C", root, *args)
      [utf8(out), utf8(err), status]
    end

    def utf8(text)
      text.dup.force_encoding(Encoding::UTF_8).scrub
    end

    # path => object id for each blob under root at sha. Symlinks (mode
    # 120000) and submodules (type commit) aren't source.
    def blob_oids(sha)
      run!("ls-tree", "-r", "-z", sha).split("\0").each_with_object({}) do |entry, oids|
        meta, path = entry.split("\t", 2)
        mode, type, oid = meta.split(" ")
        oids[path] = oid if type == "blob" && mode != "120000"
      end
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

    # File headers only count between a "diff --git" line and the first hunk,
    # so an added line that happens to start with "++ " can't pass for one.
    def parse_diff(diff)
      result = Hash.new { |h, k| h[k] = Set.new }
      current = nil
      in_header = false
      diff.each_line(chomp: true) do |line|
        if line.start_with?("diff --git ")
          in_header = true
          current = nil
        elsif in_header && line.start_with?("+++ ")
          current = new_path(line)
        elsif (m = HUNK.match(line))
          in_header = false
          add_hunk(result[current], m[1].to_i, (m[2] || "1").to_i) if current
        end
      end
      result.to_h
    end

    # git appends a tab to a header path that contains a space, and quotes a
    # path with characters it won't print raw.
    def new_path(line)
      target = line.delete_prefix("+++ ").delete_suffix("\t")
      return nil if target == "/dev/null"

      target = target.undump if target.start_with?('"')
      target.delete_prefix("b/")
    end

    def write_blobs(out, paths, dir)
      pos = 0
      paths.each do |path|
        header_end = out.index("\n", pos)
        header = out[pos...header_end]
        pos = header_end + 1
        next if header.end_with?(" missing")

        size = header.split(" ").last.to_i
        full = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.binwrite(full, out.byteslice(pos, size))
        pos += size + 1
      end
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
          result[final - 1] = uncommitted?(sha) ? Float::INFINITY : times.fetch(sha, 0)
        elsif (m = BLAME_HEADER.match(line))
          sha = m[1]
          final = m[2].to_i
        elsif line.start_with?("committer-time ")
          times[sha] = line.split(" ", 2).last.to_i
        end
      end
      result
    end

    def uncommitted?(sha)
      sha.match?(/\A0+\z/)
    end

    def newest_time(porcelain)
      return Float::INFINITY if porcelain.each_line.any? { |l| (m = BLAME_HEADER.match(l)) && uncommitted?(m[1]) }

      times = porcelain.each_line.filter_map { |l| l.split(" ", 2).last.to_i if l.start_with?("committer-time ") }
      times.max or raise GitError, "no blame data"
    end
  end
end
