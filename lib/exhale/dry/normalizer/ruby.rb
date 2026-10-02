# frozen_string_literal: true

require "prism"
require_relative "../../shape"

module Exhale
  module Dry
    module Normalizer
      # Turns a Prism node into a Shape. Names of operations survive (the
      # method name at every call site, operators included), names of things
      # become markers (":local", ":ivar", ":const", ":literal"), and the tree
      # keeps its shape. Two methods that do the same work on differently
      # named locals and constants come out equal.
      module Ruby
        MARKERS = {
          local_variable_read_node: ":local",
          it_local_variable_read_node: ":local",
          local_variable_target_node: ":local",
          required_parameter_node: ":local",
          block_local_variable_node: ":local",
          instance_variable_read_node: ":ivar",
          instance_variable_target_node: ":ivar",
          class_variable_read_node: ":cvar",
          class_variable_target_node: ":cvar",
          global_variable_read_node: ":gvar",
          global_variable_target_node: ":gvar",
          back_reference_read_node: ":gvar",
          numbered_reference_read_node: ":gvar",
          constant_read_node: ":const",
          constant_path_node: ":const",
          constant_target_node: ":const",
          constant_path_target_node: ":const",
          symbol_node: ":literal",
          string_node: ":literal",
          x_string_node: ":literal",
          integer_node: ":literal",
          float_node: ":literal",
          rational_node: ":literal",
          imaginary_node: ":literal",
          regular_expression_node: ":literal",
          true_node: ":literal",
          false_node: ":literal",
          nil_node: ":literal",
          source_file_node: ":literal",
          source_line_node: ":literal",
          source_encoding_node: ":literal"
        }.freeze

        # `a.total += 1` and `a.total ||= 1` are calls to `total`, so the
        # read name stays alongside the operator.
        CALL_WRITES = %i[call_operator_write_node call_and_write_node call_or_write_node].freeze

        # A route helper names a route, which is a thing, so
        # `edit_order_path(@order)` and `invoice_path(@invoice)` read the same.
        # The call stays a call; only its label becomes the marker.
        ROUTE_HELPER = /_(?:path|url)\z/
        ROUTE = ":route"

        module_function

        def normalize(node)
          marker = MARKERS[node.type]
          return leaf(marker, node) if marker

          case node.type
          when :statements_node then build(node, children: normalize_all(node.body), sequence: true)
          when :call_node then build(node, label: call_label(node))
          when :parentheses_node then unwrap(node)
          else build(node, label: label_for(node))
          end
        end

        def call_label(node)
          name = node.name.to_s
          node.receiver.nil? && name.match?(ROUTE_HELPER) ? ROUTE : name
        end

        def normalize_all(nodes)
          nodes.compact.map { |child| normalize(child) }
        end

        def build(node, label: nil, children: normalize_all(node.compact_child_nodes), sequence: false)
          location = node.location
          Shape.new(kind: node.type.to_s, label: label, children: children,
                    start_line: location.start_line, end_line: location.end_line, sequence: sequence)
        end

        def leaf(kind, node)
          location = node.location
          Shape.new(kind: kind, label: nil, children: [],
                    start_line: location.start_line, end_line: location.end_line, sequence: false)
        end

        # Operator writes keep their operator; every other name on a write
        # (the variable, constant or ivar being assigned) is dropped.
        def label_for(node)
          operator = node.binary_operator.to_s if node.respond_to?(:binary_operator)
          return [node.read_name.to_s, operator].compact.join(" ") if CALL_WRITES.include?(node.type)

          operator
        end

        # `(a + b)` reads the same as `a + b`.
        def unwrap(node)
          body = node.body
          return normalize(body.body.first) if body.is_a?(Prism::StatementsNode) && body.body.size == 1
          return normalize(body) if body && !body.is_a?(Prism::StatementsNode)

          build(node)
        end
      end
    end
  end
end
