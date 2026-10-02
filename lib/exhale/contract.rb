# frozen_string_literal: true

require "digest"
require "pathname"
require_relative "unit"
require_relative "errors"
require_relative "contract/markdown"
require_relative "contract/reference"
require_relative "contract/resolver"

module Exhale
  # The Contract: Markdown under <root>/contract/<primitive>/ that declares which
  # code belongs to a primitive and which units are deliberately parallel.
  class Contract
    Primitive = Struct.new(:name, :path, :covers)
    Clause = Struct.new(:primitive, :kind, :path, :line, :heading, :reason, :references, :key)

    SETTING_KEYS = { "threshold" => :threshold, "min-lines" => :min_lines, "min-nodes" => :min_nodes }.freeze

    attr_reader :primitives, :clauses, :settings, :errors

    def self.load(root, dir: "contract")
      new(root, dir).tap(&:parse)
    end

    def initialize(root, dir)
      @root = Pathname.new(root.to_s)
      @dir = dir
      @primitives = []
      @clauses = []
      @settings = {}
      @errors = []
    end

    def parse
      base = @root.join(@dir)
      return self unless base.directory?

      base.children.select(&:directory?).reject { |d| d.basename.to_s.start_with?(".") }
          .sort_by { |d| d.basename.to_s }.each { |d| parse_primitive(d) }
      @clauses.sort_by! { |c| [c.path, c.line] }
      self
    end

    private

    def parse_primitive(dir)
      name = dir.basename.to_s
      covers = []
      readme = dir.join("README.md")
      each_block(readme) { |block, rel| covers.concat(references(block, rel)) if block.info == "covers" } if readme.file?
      @primitives << Primitive.new(name, rel(dir), covers)
      duplication_files(dir).each do |file|
        each_block(file) { |block, path| duplication_block(name, block, path) }
      end
    end

    def duplication_files(dir)
      files = []
      single = dir.join("duplication.md")
      files << single if single.file?
      nested = dir.join("duplication")
      files.concat(Dir.glob("**/*.md", base: nested.to_s).sort.map { |f| nested.join(f) }) if nested.directory?
      files.sort_by(&:to_s)
    end

    def each_block(file)
      path = rel(file)
      Markdown.blocks(File.read(file)).each { |block| yield block, path }
    end

    def duplication_block(primitive, block, path)
      case block.info
      when "parallel" then add_clause(primitive, block, path)
      when "settings" then add_settings(primitive, block, path)
      end
    end

    def references(block, path)
      block.body.filter_map do |text, no|
        ref = Markdown.strip_comment(text)
        Reference.new(ref, path, no) unless ref.empty?
      end
    end

    def add_clause(primitive, block, path)
      refs = references(block, path)
      return @errors << ContractError.new(path, block.line, "empty parallel block") if refs.empty?

      key = Digest::SHA256.hexdigest("#{primitive}|parallel|#{refs.map(&:text).sort.join("\n")}")
      @clauses << Clause.new(primitive, :parallel, path, block.line, block.heading, block.reason, refs, key)
    end

    def add_settings(primitive, block, path)
      if @settings.key?(primitive)
        return @errors << ContractError.new(path, block.line, "second settings block for #{primitive}")
      end

      @settings[primitive] = block.body.each_with_object({}) do |(text, no), acc|
        line = Markdown.strip_comment(text)
        next if line.empty?

        parse_setting(line, path, no, acc)
      end
    end

    def parse_setting(line, path, no, acc)
      key, value = line.split(":", 2).map(&:strip)
      sym = SETTING_KEYS[key]
      return @errors << ContractError.new(path, no, "unknown setting: #{key}") unless sym

      parsed = setting_value(sym, value)
      return @errors << ContractError.new(path, no, "bad value for #{key}: #{value.inspect}") if parsed.nil?

      acc[sym] = parsed
    end

    def setting_value(sym, value)
      if sym == :threshold
        f = Float(value, exception: false)
        f if f && f > 0 && f <= 1
      else
        i = Integer(value.to_s, 10, exception: false)
        i if i && i >= 1
      end
    end

    def rel(path)
      Pathname.new(path.to_s).relative_path_from(@root).to_s
    end
  end
end
