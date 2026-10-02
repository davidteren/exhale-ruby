# frozen_string_literal: true

require "optparse"
require_relative "version"
require_relative "errors"
require_relative "report"
require_relative "dry/check"

module Exhale
  # exhale [dry] [PATH...] [options]
  # exhale dry explain A B
  #
  # Exit codes: 0 pass, 1 the gate failed, 2 exhale couldn't run.
  class CLI
    CHECKS = %w[dry].freeze

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
      @options = { root: Dir.pwd, format: "text", include_tests: false, contract_dir: "contract",
                   overrides: {}, introduced_only: false, base: nil, cache_dir: nil }
    end

    def run
      @argv.shift if CHECKS.include?(@argv.first)
      return explain(@argv.drop(1)) if @argv.first == "explain"

      paths = parser.parse(@argv)
      return 2 unless valid_format?

      result = Dry::Check.new(root: @options[:root], base: @options[:base], include_tests: @options[:include_tests],
                              contract_dir: @options[:contract_dir], overrides: @options[:overrides],
                              introduced_only: @options[:introduced_only], paths: paths,
                              cache_dir: @options[:cache_dir]).run
      @out.print Report.render(result, @options[:format])
      result.exit_code
    rescue OptionParser::ParseError, ArgumentError => e
      @err.puts "exhale: #{e.message}"
      @err.puts parser.banner
      2
    rescue Error => e
      @err.puts "exhale: #{e.message}"
      2
    end

    private

    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = "usage: exhale [dry] [PATH...] [options]\n       exhale dry explain IDENTITY IDENTITY"
        o.on("--base REF", "Label findings against the merge base of REF and HEAD (default: the default branch)") do |v|
          @options[:base] = v
        end
        o.on("--threshold N", Float, "Minimum score, 0 to 1 (overrides the Contract; the run won't gate)") do |v|
          @options[:overrides][:threshold] = Rational(v.to_s)
        end
        o.on("--min-lines N", Integer, "Minimum source lines (overrides the Contract; the run won't gate)") do |v|
          @options[:overrides][:min_lines] = v
        end
        o.on("--min-nodes N", Integer, "Minimum normalized nodes (overrides the Contract; the run won't gate)") do |v|
          @options[:overrides][:min_nodes] = v
        end
        o.on("--format F", "text, json or edn (default text)") { |v| @options[:format] = v }
        o.on("--include-tests", "Compare spec/ and test/ too") { @options[:include_tests] = true }
        o.on("--introduced-only", "On-ramp: gate only on introduced and shifted findings") do
          @options[:introduced_only] = true
        end
        o.on("--contract DIR", "The Contract's root (default contract/)") { |v| @options[:contract_dir] = v }
        o.on("--cache DIR", "Cache directory (default tmp/exhale/)") { |v| @options[:cache_dir] = v }
        o.on("--root DIR", "Repository root (default: the current directory)") { |v| @options[:root] = v }
        o.on("-v", "--version", "Print the version") do
          @out.puts "exhale #{VERSION}"
          exit 0
        end
        o.on("-h", "--help", "Print this help") do
          @out.puts o
          exit 0
        end
      end
    end

    def valid_format?
      return true if Report::FORMATS.include?(@options[:format])

      @err.puts "exhale: unknown format #{@options[:format].inspect} (use text, json or edn)"
      false
    end

    # Prints two units' normalized trees and their score, for tuning.
    def explain(args)
      args = parser.parse(args)
      unless args.size == 2
        @err.puts "usage: exhale dry explain IDENTITY IDENTITY"
        return 2
      end

      sweep = Dry::Sweep.new(File.expand_path(@options[:root]), include_tests: @options[:include_tests],
                                                                  contract_dir: @options[:contract_dir]).run
      a, b = args.map { |identity| sweep.index.entries.find { |e| e.unit.identity == identity } }
      missing = args.zip([a, b]).find { |_, entry| entry.nil? }
      if missing
        @err.puts "exhale: no unit named #{missing[0]}"
        return 2
      end

      [a, b].each do |entry|
        @out.puts "#{entry.unit.identity}  #{entry.unit.path}:#{entry.unit.start_line}-#{entry.unit.end_line}"
        print_shape(Dry::Normalizer.normalize(entry.unit), 1)
        @out.puts
      end
      shared = a.set & b.set
      @out.puts "score #{Report.score(sweep.index.score(a.set, a.total, b.set, b.total))}, " \
                "#{shared.size} shared of #{(a.set | b.set).size} fingerprints"
      0
    end

    def print_shape(shape, depth)
      label = shape.label ? " #{shape.label}" : ""
      @out.puts "#{'  ' * depth}#{shape.kind}#{label}"
      shape.children.each { |child| print_shape(child, depth + 1) }
    end
  end
end
