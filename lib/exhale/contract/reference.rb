# frozen_string_literal: true

module Exhale
  class Contract
    # A line from a covers or parallel block, with where it was written.
    Reference = Struct.new(:text, :path, :line) do
      def kind
        if text.include?("/") then :template_glob
        elsif text.match?(/[#.]/) then :method
        elsif text.include?("*") then :const_glob
        else :constant
        end
      end

      # Method refs beat constants, which beat globs.
      def rank
        { method: 3, constant: 2 }.fetch(kind, 1)
      end

      def const_segments
        text.split("::")
      end

      def template_regex
        pieces = text.split(%r{(/\*\*/|\*\*/|/\*\*\z|\*\*|\*)})
        body = pieces.map { |p| TEMPLATE_TOKENS.fetch(p) { Regexp.escape(p) } }.join
        Regexp.new("\\A#{body}\\z")
      end

      TEMPLATE_TOKENS = {
        "/**/" => "/(?:.*/)?", "**/" => "(?:.*/)?", "/**" => "/.*", "**" => ".*", "*" => "[^/]*"
      }.freeze

      # Does a namespace prefix (an Array of segments) match this constant glob?
      def const_glob_match?(segments)
        self.class.seg_match?(const_segments, segments)
      end

      def self.seg_match?(pats, segs)
        return segs.empty? if pats.empty?

        if pats[0] == "**"
          (0..segs.size).any? { |n| seg_match?(pats[1..], segs[n..]) }
        else
          !segs.empty? && File.fnmatch?(pats[0], segs[0]) && seg_match?(pats[1..], segs[1..])
        end
      end
    end
  end
end
