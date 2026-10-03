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

      # Orders references by how narrowly they point: method refs first, then
      # more literal segments, more segments, fewer "**", longer text.
      def specificity
        return [1, 0, 0, 0, text.length] if kind == :method

        segs = kind == :template_glob ? text.split("/") : const_segments
        [0, segs.count { |s| !s.include?("*") }, segs.size, -segs.count("**"), text.length]
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

      # Bottom-up DP over (pattern index, segment index): O(patterns * segments)
      # however many "**" the pattern holds.
      def self.seg_match?(pats, segs)
        np = pats.size
        ns = segs.size
        # ok[j]: pats[i..] matches segs[j..], built for i from np down to 0.
        ok = Array.new(ns + 1) { |j| j == ns }
        (np - 1).downto(0) do |i|
          nxt = ok
          ok = Array.new(ns + 1, false)
          if pats[i] == "**"
            ns.downto(0) { |j| ok[j] = nxt[j] || (j < ns && ok[j + 1]) }
          else
            ns.times { |j| ok[j] = nxt[j + 1] && File.fnmatch?(pats[i], segs[j]) }
          end
        end
        ok[0]
      end
    end
  end
end
