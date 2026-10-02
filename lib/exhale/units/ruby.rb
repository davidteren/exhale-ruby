# frozen_string_literal: true

require "prism"
require_relative "../errors"
require_relative "../unit"

module Exhale
  module Units
    # Finds the units in one Ruby file: methods, and the bodies of Rails DSL
    # calls (scopes, callbacks, validations, rescue_from, job hooks).
    module Ruby
      DSL = %i[
        scope default_scope validate validates_each
        before_validation after_validation
        before_save around_save after_save before_create around_create after_create
        before_update around_update after_update before_destroy around_destroy after_destroy
        after_commit after_create_commit after_update_commit after_destroy_commit after_save_commit after_rollback
        after_initialize after_find after_touch
        before_action after_action around_action prepend_before_action append_before_action
        prepend_after_action append_after_action rescue_from
        before_perform after_perform around_perform before_enqueue after_enqueue around_enqueue
      ].freeze

      # Concern blocks whose contents read as the class body itself.
      CLASS_BODIES = %i[included prepended concerning].freeze

      module_function

      def extract(source, path)
        result = Prism.parse(source)
        if result.failure?
          error = result.errors.first
          raise ParseError.new(path, error.location.start_line, error.message)
        end

        Walker.new(path).walk(result.value)
      end

      # Walks a file keeping the namespace a statement sits in, and whether
      # it sits in a singleton body (`class << self`, `class_methods do`).
      class Walker
        def initialize(path)
          @path = path
          @units = []
          @ordinals = Hash.new(0)
        end

        def walk(program)
          visit(program, "Object", false)
          @units
        end

        private

        def visit(node, namespace, singleton)
          case node
          when Prism::ModuleNode, Prism::ClassNode
            visit_body(node.body, nest(namespace, node.constant_path), false)
          when Prism::SingletonClassNode then visit_body(node.body, namespace, true)
          when Prism::DefNode then add_method(node, namespace, singleton)
          when Prism::ConstantWriteNode then constant_write(node, namespace, singleton)
          when Prism::CallNode then call(node, namespace, singleton)
          else visit_children(node, namespace, singleton)
          end
        end

        def visit_body(body, namespace, singleton)
          visit(body, namespace, singleton) if body
        end

        def visit_children(node, namespace, singleton)
          node.compact_child_nodes.each { |child| visit(child, namespace, singleton) }
        end

        # A def nested inside this one belongs to it, so the walk stops here.
        def add_method(node, namespace, singleton)
          separator = singleton || node.receiver ? "." : "#"
          add(:method, node, namespace, node.name.to_s, separator)
        end

        # `Point = Struct.new(:x) do ... end` and `Class.new do ... end`
        # define their methods on the constant.
        def constant_write(node, namespace, singleton)
          value = node.value
          if value.is_a?(Prism::CallNode) && value.block.is_a?(Prism::BlockNode)
            visit_body(value.block.body, join(namespace, node.name.to_s), false)
          else
            visit_children(node, namespace, singleton)
          end
        end

        def call(node, namespace, singleton)
          return visit_children(node, namespace, singleton) if node.receiver

          block = node.block if node.block.is_a?(Prism::BlockNode)
          if node.name == :define_method && block then define_method(node, block, namespace, singleton)
          elsif CLASS_BODIES.include?(node.name) && block then visit_body(block.body, namespace, false)
          elsif node.name == :class_methods && block then visit_body(block.body, namespace, true)
          elsif DSL.include?(node.name) && (body = block || lambda_argument(node)) then add_dsl(node, body, namespace)
          else visit_children(node, namespace, singleton)
          end
        end

        def define_method(node, block, namespace, singleton)
          separator = singleton ? "." : "#"
          name = literal_name(node) || "define_method[#{next_ordinal(namespace, :define_method)}]"
          add(:method, block, namespace, name, separator)
        end

        def add_dsl(node, body, namespace)
          symbol = node.arguments&.arguments&.first
          name = if symbol.is_a?(Prism::SymbolNode)
                   "#{node.name}(:#{symbol.unescaped})"
                 else
                   "#{node.name}[#{next_ordinal(namespace, node.name)}]"
                 end
          add(:dsl, body, namespace, name, ".")
        end

        # `scope :x, -> { ... }`, or the older `scope :x, lambda { ... }`.
        def lambda_argument(node)
          Array(node.arguments&.arguments).each do |argument|
            return argument if argument.is_a?(Prism::LambdaNode)
            return argument.block if lambda_call?(argument)
          end
          nil
        end

        def lambda_call?(node)
          node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[lambda proc].include?(node.name) &&
            node.block.is_a?(Prism::BlockNode)
        end

        def literal_name(node)
          first = node.arguments&.arguments&.first
          first.unescaped if first.is_a?(Prism::SymbolNode) || first.is_a?(Prism::StringNode)
        end

        def next_ordinal(namespace, macro)
          @ordinals[[namespace, macro]] += 1
        end

        def add(kind, node, namespace, name, separator)
          location = node.location
          @units << Unit.new(kind: kind, identity: "#{namespace}#{separator}#{name}", namespace: namespace,
                             name: name, path: @path, start_line: location.start_line,
                             end_line: location.end_line, language: :ruby, node: node)
        end

        def nest(namespace, constant_path)
          rooted, name = constant_name(constant_path)
          rooted ? name : join(namespace, name)
        end

        def join(namespace, name)
          namespace == "Object" ? name : "#{namespace}::#{name}"
        end

        # [rooted, "Foo::Bar"]. rooted is true for a leading `::`.
        def constant_name(node)
          case node
          when Prism::ConstantReadNode then [false, node.name.to_s]
          when Prism::ConstantPathNode
            return [true, node.name.to_s] if node.parent.nil?

            rooted, parent = constant_name(node.parent)
            [rooted, "#{parent}::#{node.name}"]
          else [false, node.slice]
          end
        end
      end
    end
  end
end
