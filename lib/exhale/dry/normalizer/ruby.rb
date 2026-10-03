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
        # Receivers that hand out route helpers: `main_app.orders_path`,
        # `Rails.application.routes.url_helpers.order_url(o)`. On any other
        # receiver (`request.original_url`, `blob.service_url`) the name is
        # the receiver's own method and stays.
        ROUTE_PROXIES = %i[url_helpers main_app helpers routes].freeze

        # Stimulus names behavior in Ruby too: `data: { controller: "modal" }`
        # and `"data-controller" => "modal"` keep their value, as the HTML
        # attribute does.
        STIMULUS_HASH_KEYS = %w[controller action].freeze
        STIMULUS_KEYS = %w[data-controller data-action].freeze
        STIMULUS = "stimulus_value"

        module_function

        # template: true reads a bare identifier (`order`, no receiver, no
        # arguments) as a local. In a partial that is what it almost always
        # is, and Prism can't tell because the locals come from `render`.
        def normalize(node, template: false)
          Walker.new(template).normalize(node)
        end

        class Walker
          def initialize(template)
            @template = template
          end

          def normalize(node)
            marker = MARKERS[node.type]
            return leaf(marker, node) if marker

            case node.type
            when :statements_node then build(node, children: normalize_all(node.body), sequence: true)
            when :call_node then call(node)
            when :parentheses_node then unwrap(node)
            when :assoc_node then assoc(node)
            else build(node, label: label_for(node))
            end
          end

          private

          def normalize_all(nodes)
            nodes.compact.map { |child| normalize(child) }
          end

          def call(node)
            return leaf(":local", node) if @template && node.variable_call?

            build(node, label: route_helper?(node) ? ROUTE : node.name.to_s)
          end

          def route_helper?(node)
            return false unless node.name.to_s.match?(ROUTE_HELPER)

            receiver = node.receiver
            receiver.nil? || (receiver.is_a?(Prism::CallNode) && ROUTE_PROXIES.include?(receiver.name))
          end

          # `(a + b)` reads the same as `a + b`.
          def unwrap(node)
            body = node.body
            return normalize(body.body.first) if body.is_a?(Prism::StatementsNode) && body.body.size == 1
            return normalize(body) if body && !body.is_a?(Prism::StatementsNode)

            build(node)
          end

          def assoc(node)
            key = key_text(node.key)
            value = node.value
            if key == "data" && value.is_a?(Prism::HashNode)
              build(node, children: [normalize(node.key), stimulus_hash(value)])
            elsif STIMULUS_KEYS.include?(key) && value.is_a?(Prism::StringNode)
              build(node, children: [normalize(node.key), stimulus(value)])
            else
              build(node)
            end
          end

          def stimulus_hash(hash)
            children = hash.elements.map do |element|
              if element.is_a?(Prism::AssocNode) && STIMULUS_HASH_KEYS.include?(key_text(element.key)) &&
                 element.value.is_a?(Prism::StringNode)
                build(element, children: [normalize(element.key), stimulus(element.value)])
              else
                normalize(element)
              end
            end
            build(hash, children: children)
          end

          def stimulus(string)
            build(string, kind: STIMULUS, label: string.unescaped, children: [])
          end

          def key_text(key)
            key.unescaped if key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode)
          end

          # Operator writes keep their operator; every other name on a write
          # (the variable, constant or ivar being assigned) is dropped.
          def label_for(node)
            operator = node.binary_operator.to_s if node.respond_to?(:binary_operator)
            return [node.read_name.to_s, operator].compact.join(" ") if CALL_WRITES.include?(node.type)

            operator
          end

          def build(node, kind: node.type.to_s, label: nil, children: normalize_all(node.compact_child_nodes),
                    sequence: false)
            Shape.new(kind: kind, label: label, children: children, sequence: sequence,
                      start_line: node.location.start_line, end_line: end_line(node, children))
          end

          def leaf(kind, node)
            Shape.new(kind: kind, label: nil, children: [], sequence: false,
                      start_line: node.location.start_line, end_line: end_line(node, []))
          end

          # A heredoc's body and terminator sit below the line its node
          # ends on, so a shape ends at the furthest terminator inside it.
          def end_line(node, children)
            last = node.location.end_line
            last = [last, node.closing_loc.start_line].max if heredoc?(node)
            children.empty? ? last : [last, children.map(&:end_line).max].max
          end

          def heredoc?(node)
            node.respond_to?(:heredoc?) && node.heredoc? && node.closing_loc
          end
        end
      end
    end
  end
end
