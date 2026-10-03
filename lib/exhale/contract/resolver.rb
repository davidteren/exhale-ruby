# frozen_string_literal: true

require_relative "../unit"
require_relative "../errors"
require_relative "reference"

module Exhale
  class Contract
    # Maps Contract references onto code units. Units are indexed once (by
    # identity and by every namespace prefix) so each reference costs a hash
    # lookup instead of a scan.
    class Resolver
      def initialize(contract, units)
        @contract = contract
        @units = units
        @order = {}.compare_by_identity
        units.each_with_index { |u, i| @order[u] = i }
        @matches = {}
        build_indexes
      end

      def errors
        @errors ||= all_references.sort_by { |r| [r.path, r.line] }.filter_map do |ref|
          next unless units_for(ref).empty?

          ContractError.new(ref.path, ref.line, "reference names no unit: #{ref.text}")
        end
      end

      def units_for(reference)
        @units_for ||= {}
        @units_for[reference.text] ||= matches(reference).keys.sort_by { |u| @order[u] }
      end

      def keeping_clause(unit_a, unit_b)
        return nil if unit_a.equal?(unit_b)

        @contract.clauses.find { |clause| keeps?(clause, unit_a, unit_b) }
      end

      def primitive_for(unit)
        pairs = covering(unit)
        top = pairs.map { |_, ref| ref.specificity }.max
        pairs.select { |_, ref| ref.specificity == top }.map(&:first).min_by(&:name)
      end

      def settings_for(unit, defaults)
        prim = primitive_for(unit)
        defaults.merge(prim ? @contract.settings.fetch(prim.name, {}) : {})
      end

      def settings_for_pair(unit_a, unit_b, defaults)
        a = settings_for(unit_a, defaults)
        b = settings_for(unit_b, defaults)
        a.merge(b) { |_key, x, y| [x, y].min }
      end

      private

      def build_indexes
        @by_identity = Hash.new { |h, k| h[k] = [] }
        @by_prefix = Hash.new { |h, k| h[k] = [] }
        @templates = []
        @units.each { |unit| index(unit) }
      end

      def index(unit)
        @templates << unit if unit.kind == :template
        @by_identity[unit.identity] << unit if %i[method dsl].include?(unit.kind)
        return unless unit.namespace

        segments = unit.namespace.split("::")
        (1..segments.size).each { |n| @by_prefix[segments.first(n).join("::")] << unit }
      end

      def all_references
        @contract.primitives.flat_map(&:covers) + @contract.clauses.flat_map(&:references)
      end

      # {unit => match key}, cached per reference text.
      def matches(ref)
        @matches[ref.text] ||= case ref.kind
                               when :method then method_matches(ref)
                               when :constant then constant_matches(ref)
                               when :const_glob then const_glob_matches(ref)
                               else template_matches(ref)
                               end
      end

      def method_matches(ref)
        @by_identity.fetch(ref.text, []).to_h { |u| [u, ref.text] }.compare_by_identity
      end

      def constant_matches(ref)
        @by_prefix.fetch(ref.text, []).to_h { |u| [u, ref.text] }.compare_by_identity
      end

      # A unit under several matching prefixes keys on the longest one.
      def const_glob_matches(ref)
        result = {}.compare_by_identity
        @by_prefix.each do |prefix, units|
          next unless ref.const_glob_match?(prefix.split("::"))

          units.each { |u| result[u] = prefix if !result.key?(u) || result[u].length < prefix.length }
        end
        result
      end

      def template_matches(ref)
        regex = ref.template_regex
        @templates.select { |u| regex.match?(u.identity) }.to_h { |u| [u, u.identity] }.compare_by_identity
      end

      def keeps?(clause, unit_a, unit_b)
        a = assignment(clause, unit_a)
        b = assignment(clause, unit_b)
        a && b && a != b
      end

      # The one reference (and match key) a unit belongs to within a clause:
      # the most specific of those that match it.
      def assignment(clause, unit)
        hits = clause.references.uniq(&:text).filter_map { |r| (k = matches(r)[unit]) && [r, k] }
        ref, key = hits.max_by { |r, _| r.specificity }
        ref && [ref.text, key]
      end

      def covering(unit)
        @covered_by ||= build_covered_by
        @covered_by.fetch(unit, [])
      end

      def build_covered_by
        map = {}.compare_by_identity
        @contract.primitives.each do |prim|
          prim.covers.each { |ref| matches(ref).each_key { |u| (map[u] ||= []) << [prim, ref] } }
        end
        map
      end
    end
  end
end
