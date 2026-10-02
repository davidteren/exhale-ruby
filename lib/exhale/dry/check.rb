# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "../errors"
require_relative "../git"
require_relative "../source_files"
require_relative "../units/ruby"
require_relative "../units/erb"
require_relative "../contract"
require_relative "normalizer"
require_relative "fingerprints"
require_relative "index"
require_relative "matcher"
require_relative "gate"

module Exhale
  module Dry
    DEFAULTS = { threshold: Rational(80, 100), min_lines: 4, min_nodes: 20 }.freeze

    # Everything one tree yields: its units, their index, the Contract read
    # from the same tree, and every match over the threshold.
    class Sweep
      attr_reader :root, :units, :parse_errors, :contract, :resolver, :index, :matches

      def initialize(root, files: nil, include_tests: false, contract_dir: "contract", overrides: {})
        @root = root
        @files = files
        @include_tests = include_tests
        @contract_dir = contract_dir
        @overrides = overrides
      end

      def run
        @parse_errors = []
        @units = read_units
        @contract = Contract.load(@root, dir: @contract_dir)
        @resolver = Contract::Resolver.new(@contract, @units)
        @index = Index.new(entries)
        @matches = Matcher.new(@index, floors: floors, settings_for_pair: method(:settings_for_pair)).matches
        self
      end

      def settings_for_pair(a, b)
        return DEFAULTS.merge(@overrides) unless @overrides.empty?

        exact(@resolver.settings_for_pair(a, b, DEFAULTS))
      end

      private

      def read_units
        SourceFiles.list(@root, files: @files, include_tests: @include_tests).flat_map do |path, language|
          source = File.read(File.join(@root, path), encoding: "UTF-8")
          language == :ruby ? Units::Ruby.extract(source, path) : Units::Erb.extract(source, path)
        rescue ParseError => e
          @parse_errors << e
          []
        end
      end

      def entries
        @units.each_with_index.map do |unit, id|
          tree = Fingerprints.build(Normalizer.normalize(unit))
          Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
        end
      end

      # Candidates are generated at the loosest floors any primitive asks
      # for; each pair is then judged by its own settings.
      def floors
        all = [DEFAULTS.merge(@overrides)]
        all.concat(@contract.settings.values.map { |settings| DEFAULTS.merge(settings) }) if @overrides.empty?
        { min_lines: all.map { |s| s[:min_lines] }.min, min_nodes: all.map { |s| s[:min_nodes] }.min,
          threshold: all.map { |s| Rational(s[:threshold].to_s) }.min }
      end

      # Contract thresholds arrive as Floats; scores are Rationals. Reading
      # the Float's decimal text keeps 0.75 exactly 3/4.
      def exact(settings)
        settings.merge(threshold: Rational(settings[:threshold].to_s))
      end
    end

    # The duplication check: sweeps the tree on disk, sweeps the merge base
    # for labels, and hands both to the Gate for the verdict.
    class Check
      def initialize(root:, base: nil, include_tests: false, contract_dir: "contract", overrides: {},
                     introduced_only: false, paths: [], cache_dir: nil)
        @root = File.expand_path(root)
        @base_ref = base
        @include_tests = include_tests
        @contract_dir = contract_dir
        @overrides = overrides
        @introduced_only = introduced_only
        @paths = paths
        @cache_dir = cache_dir || File.join(@root, "tmp", "exhale")
        @git = Git.new(@root)
      end

      def run
        head = Sweep.new(@root, files: (@git.files if @git.repo?), include_tests: @include_tests,
                                contract_dir: @contract_dir, overrides: @overrides).run
        base_sha = find_base
        Gate.new(head: head, base: base_sha && base_summary(base_sha), base_sha: base_sha, git: (@git if @git.repo?),
                 changed_lines: base_sha ? @git.changed_lines(base_sha) : {},
                 introduced_only: @introduced_only, paths: @paths, overrides: @overrides).verdict
      end

      private

      def find_base
        return unless @git.repo?

        ref = @base_ref || @git.default_branch_ref
        ref && @git.merge_base(ref)
      end

      # What the Gate needs from the base, cached on disk by SHA, exhale
      # version and normalizer version.
      def base_summary(sha)
        path = File.join(@cache_dir, "base-#{sha}-#{VERSION}-n#{Normalizer::VERSION}.marshal")
        cached = read_cache(path)
        return cached if cached

        summary = Dir.mktmpdir("exhale-base") do |dir|
          @git.export(sha, dir)
          sweep = Sweep.new(dir, files: @git.files_at(sha), include_tests: @include_tests,
                                 contract_dir: @contract_dir).run
          Gate.summarize(sweep)
        end
        write_cache(path, summary)
        summary
      end

      def read_cache(path)
        return unless File.exist?(path)

        Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
      rescue StandardError
        nil
      end

      def write_cache(path, summary)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, Marshal.dump(summary))
      rescue SystemCallError
        nil
      end
    end
  end
end
