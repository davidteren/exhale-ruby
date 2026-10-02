# frozen_string_literal: true

require "test_helper"
require "prism"
require "exhale/dry/normalizer/ruby"

class NormalizerRubyTest < Minitest::Test
  def test_methods_doing_the_same_work_on_different_names_are_equal
    alpha = statement(<<~RUBY)
      def alpha(xs)
        ys = xs.select(&:odd?)
        ys.map(&:succ)
      end
    RUBY
    beta = statement(<<~RUBY)
      def beta(items)
        kept = items.select(&:even?)
        kept.map(&:pred)
      end
    RUBY

    assert_equal project(normalize(alpha)), project(normalize(beta))
  end

  def test_a_local_read_and_a_bare_call_differ
    local = normalize(statement("def a(user) = user.name"))
    call = normalize(statement("def a(user) = current_user.name"))

    refute_equal project(local), project(call)
  end

  def test_receivers_and_hash_values_become_markers
    assert_equal project(normalize(statement("User.where(active: true)"))),
                 project(normalize(statement("Account.where(enabled: false)")))
  end

  def test_call_names_survive
    refute_equal project(normalize(statement("x.select { _1 }"))), project(normalize(statement("x.reject { _1 }")))
    refute_equal project(normalize(statement("a + b"))), project(normalize(statement("a - b")))
  end

  def test_route_helpers_name_a_route_so_their_names_become_a_marker
    assert_equal project(normalize(statement("redirect_to edit_order_path(@order)"))),
                 project(normalize(statement("redirect_to invoice_url(@invoice)")))
    assert_equal ["call_node", ":route"], project(normalize(statement("root_path")))
    assert_equal ["call_node", "full_path", [":local", nil]], project(normalize(statement("r = 1; r.full_path", index: 1)))
  end

  def test_call_shape_keeps_name_receiver_arguments_and_block
    shape = normalize(statement("order.items.where(state: :paid) { |i| i }"))

    assert_equal ["call_node", "where",
                  ["call_node", "items", ["call_node", "order"]],
                  ["arguments_node", nil, ["keyword_hash_node", nil, ["assoc_node", nil, [":literal", nil], [":literal", nil]]]],
                  ["block_node", nil,
                   ["block_parameters_node", nil, ["parameters_node", nil, [":local", nil]]],
                   ["statements_node", nil, [":local", nil]]]],
                 project(shape)
  end

  def test_def_drops_its_name_and_marks_its_body_as_a_sequence
    shape = normalize(statement(<<~RUBY))
      def total(rate = 2)
        @sum = @base * rate
        TAX + 1
      end
    RUBY

    assert_equal ["def_node", nil,
                  ["parameters_node", nil, ["optional_parameter_node", nil, [":literal", nil]]],
                  ["statements_node", nil,
                   ["instance_variable_write_node", nil, ["call_node", "*", [":ivar", nil], ["arguments_node", nil, [":local", nil]]]],
                   ["call_node", "+", [":const", nil], ["arguments_node", nil, [":literal", nil]]]]],
                 project(shape)
    assert shape.children.last.sequence
    refute shape.sequence
    assert_equal [1, 4], [shape.start_line, shape.end_line]
    assert_equal [2, 3], [shape.children.last.start_line, shape.children.last.end_line]
  end

  def test_singleton_def_keeps_self_receiver
    shape = normalize(statement("def self.build = new"))

    assert_equal ["def_node", nil, ["self_node", nil], ["statements_node", nil, ["call_node", "new"]]], project(shape)
  end

  def test_operator_writes_keep_the_operator_and_drop_the_name
    assert_equal ["local_variable_operator_write_node", "+", [":literal", nil]], project(normalize(statement("x += 1")))
    assert_equal ["instance_variable_or_write_node", nil, [":literal", nil]], project(normalize(statement("@x ||= 1")))
    assert_equal ["call_operator_write_node", "count +", [":local", nil], [":literal", nil]],
                 project(normalize(statement("a = 1; a.count += 1", index: 1)))
  end

  def test_constants_and_globals_become_markers
    assert_equal [":const", nil], project(normalize(statement("Billing::Invoice")))
    assert_equal [":const", nil], project(normalize(statement("::Invoice")))
    assert_equal [":gvar", nil], project(normalize(statement("$stdout")))
    assert_equal [":cvar", nil], project(normalize(statement("@@count")))
    assert_equal ["constant_write_node", nil, [":literal", nil]], project(normalize(statement("RATE = 3")))
  end

  def test_interpolated_strings_keep_their_kind_and_normalize_embedded_code
    shape = normalize(statement('"Hello #{name}!"'))

    assert_equal ["interpolated_string_node", nil,
                  [":literal", nil],
                  ["embedded_statements_node", nil, ["statements_node", nil, ["call_node", "name"]]],
                  [":literal", nil]],
                 project(shape)
  end

  def test_literals_of_any_kind_become_the_same_marker
    %w[:sym 'str' 1 1.5 2r 3i /re/ true false nil __FILE__ __LINE__].each do |source|
      assert_equal [":literal", nil], project(normalize(statement(source))), source
    end
  end

  def test_parentheses_around_one_statement_unwrap
    assert_equal project(normalize(statement("a + b"))), project(normalize(statement("(a + b)")))
  end

  private

  def statement(source, index: 0)
    Prism.parse(source).value.statements.body[index]
  end

  def normalize(node)
    Exhale::Dry::Normalizer::Ruby.normalize(node)
  end

  # Shapes compare with their line numbers; this view compares structure.
  def project(shape)
    [shape.kind, shape.label, *shape.children.map { |child| project(child) }]
  end
end
