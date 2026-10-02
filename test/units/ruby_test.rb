# frozen_string_literal: true

require "test_helper"
require "exhale/units/ruby"

class UnitsRubyTest < Minitest::Test
  def test_nested_modules_and_compact_class_paths
    units = extract(<<~RUBY)
      module Billing
        class Invoice
          def total; end
        end

        class Line::Item
          def amount; end
        end

        class ::Ledger
          def post; end
        end
      end

      def helper; end
    RUBY

    assert_equal ["Billing::Invoice#total", "Billing::Line::Item#amount", "Ledger#post", "Object#helper"],
                 units.map(&:identity)
    assert_equal ["Billing::Invoice", "Billing::Line::Item", "Ledger", "Object"], units.map(&:namespace)
    assert_equal %w[total amount post helper], units.map(&:name)
  end

  def test_singleton_methods
    units = extract(<<~RUBY)
      class Invoice
        def self.build; end

        class << self
          def find_due; end
        end

        def total; end
      end
    RUBY

    assert_equal ["Invoice.build", "Invoice.find_due", "Invoice#total"], units.map(&:identity)
  end

  def test_unit_fields
    unit = extract(<<~RUBY, "app/models/invoice.rb").first
      class Invoice
        def total
          lines.sum(&:amount)
        end
      end
    RUBY

    assert_equal :method, unit.kind
    assert_equal "app/models/invoice.rb", unit.path
    assert_equal :ruby, unit.language
    assert_equal [2, 4], [unit.start_line, unit.end_line]
    assert_instance_of Prism::DefNode, unit.node
  end

  def test_a_def_inside_a_def_belongs_to_the_outer_method
    units = extract(<<~RUBY)
      class Invoice
        def setup
          def helper; end
        end
      end
    RUBY

    assert_equal ["Invoice#setup"], units.map(&:identity)
  end

  def test_define_method_is_a_method_unit
    units = extract(<<~RUBY)
      class Invoice
        define_method(:paid?) { state == "paid" }
        define_method :due? do
          state == "due"
        end
      end
    RUBY

    assert_equal ["Invoice#paid?", "Invoice#due?"], units.map(&:identity)
    assert_equal [:method, :method], units.map(&:kind)
    assert units.all? { |unit| unit.node.is_a?(Prism::BlockNode) }
    assert_equal [3, 5], [units.last.start_line, units.last.end_line]
  end

  def test_scope_with_a_lambda
    unit = extract(<<~RUBY).first
      class Order < ApplicationRecord
        scope :settled, -> { where(state: :settled) }
      end
    RUBY

    assert_equal ["Order.scope(:settled)", "scope(:settled)", "Order", :dsl],
                 [unit.identity, unit.name, unit.namespace, unit.kind]
    assert_instance_of Prism::LambdaNode, unit.node
  end

  def test_callback_blocks_named_and_numbered
    units = extract(<<~RUBY)
      class OrdersController < ApplicationController
        before_action do
          authenticate!
        end
        before_action :load_order do
          @order = Order.find(params[:id])
        end
        before_action { track! }
        after_action { log! }
      end
    RUBY

    assert_equal ["OrdersController.before_action[1]", "OrdersController.before_action(:load_order)",
                  "OrdersController.before_action[2]", "OrdersController.after_action[1]"],
                 units.map(&:identity)
    assert units.all? { |unit| unit.node.is_a?(Prism::BlockNode) }
  end

  def test_concern_blocks_read_as_the_class_body
    units = extract(<<~RUBY)
      module Billable
        extend ActiveSupport::Concern

        included do
          before_save { normalize_amount }
          def bill; end
        end

        class_methods do
          def billable; end
        end

        concerning :Refunds do
          def refund; end
        end
      end
    RUBY

    assert_equal ["Billable.before_save[1]", "Billable#bill", "Billable.billable", "Billable#refund"],
                 units.map(&:identity)
  end

  def test_class_body_macros_without_a_body_are_not_units
    units = extract(<<~RUBY)
      class Order < ApplicationRecord
        has_many :lines, -> { order(:position) }
        belongs_to :customer
        validates :total, presence: true
        before_save :normalize
        before_save :recalculate, if: -> { lines_changed? }
        scope :recent, :ordered
      end
    RUBY

    assert_empty units
  end

  def test_units_come_in_source_order
    units = extract(<<~RUBY)
      class Order
        def a; end
        validate { check }
        def b; end
      end
    RUBY

    assert_equal ["Order#a", "Order.validate[1]", "Order#b"], units.map(&:identity)
  end

  def test_parse_errors_raise_with_the_line
    error = assert_raises(Exhale::ParseError) { extract("class Order\n  def total(\nend\n", "app/models/order.rb") }

    assert_equal "app/models/order.rb", error.path
    assert_kind_of Integer, error.line
    assert_match(/\Aapp\/models\/order\.rb:\d+: /, error.message)
  end

  private

  def extract(source, path = "app/models/example.rb")
    Exhale::Units::Ruby.extract(source, path)
  end
end
