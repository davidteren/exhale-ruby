# frozen_string_literal: true

require "test_helper"
require "prism"
require "exhale/dry/normalizer/ruby"

class NormalizerRubyTest < Minitest::Test
  # Contract: shape/N2
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

  # Contract: shape/N1
  def test_a_local_read_and_a_bare_call_differ
    local = normalize(statement("def a(user) = user.name"))
    call = normalize(statement("def a(user) = current_user.name"))

    refute_equal project(local), project(call)
  end

  # Contract: shape/N2
  def test_receivers_and_hash_values_become_markers
    assert_equal project(normalize(statement("User.where(active: true)"))),
                 project(normalize(statement("Account.where(enabled: false)")))
  end

  # Contract: shape/N1
  def test_call_names_survive
    refute_equal project(normalize(statement("x.select { _1 }"))), project(normalize(statement("x.reject { _1 }")))
    refute_equal project(normalize(statement("a + b"))), project(normalize(statement("a - b")))
  end

  # Contract: shape/N2
  def test_route_helpers_name_a_route_so_their_names_become_a_marker
    assert_equal project(normalize(statement("redirect_to edit_order_path(@order)"))),
                 project(normalize(statement("redirect_to invoice_url(@invoice)")))
    assert_equal ["call_node", ":route"], project(normalize(statement("root_path")))
    assert_equal ["call_node", "full_path", [":local", nil]], project(normalize(statement("r = 1; r.full_path", index: 1)))
  end

  # Contract: shape/N1
  # Contract: shape/N2
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

  # Contract: shape/N1
  # Contract: shape/N2
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

  # Contract: shape/N1
  def test_singleton_def_keeps_self_receiver
    shape = normalize(statement("def self.build = new"))

    assert_equal ["def_node", nil, ["self_node", nil], ["statements_node", nil, ["call_node", "new"]]], project(shape)
  end

  # Contract: shape/N1
  # Contract: shape/N2
  def test_operator_writes_keep_the_operator_and_drop_the_name
    assert_equal ["local_variable_operator_write_node", "+", [":literal", nil]], project(normalize(statement("x += 1")))
    assert_equal ["instance_variable_or_write_node", nil, [":literal", nil]], project(normalize(statement("@x ||= 1")))
    assert_equal ["call_operator_write_node", "count +", [":local", nil], [":literal", nil]],
                 project(normalize(statement("a = 1; a.count += 1", index: 1)))
  end

  # Contract: shape/N2
  def test_constants_and_globals_become_markers
    assert_equal [":const", nil], project(normalize(statement("Billing::Invoice")))
    assert_equal [":const", nil], project(normalize(statement("::Invoice")))
    assert_equal [":gvar", nil], project(normalize(statement("$stdout")))
    assert_equal [":cvar", nil], project(normalize(statement("@@count")))
    assert_equal ["constant_write_node", nil, [":literal", nil]], project(normalize(statement("RATE = 3")))
  end

  # Contract: shape/N2
  def test_interpolated_strings_keep_their_kind_and_normalize_embedded_code
    shape = normalize(statement('"Hello #{name}!"'))

    assert_equal ["interpolated_string_node", nil,
                  [":literal", nil],
                  ["embedded_statements_node", nil, ["statements_node", nil, ["call_node", "name"]]],
                  [":literal", nil]],
                 project(shape)
  end

  # Contract: shape/N2
  def test_literals_of_any_kind_become_the_same_marker
    %w[:sym 'str' 1 1.5 2r 3i /re/ true false nil __FILE__ __LINE__].each do |source|
      assert_equal [":literal", nil], project(normalize(statement(source))), source
    end
  end

  def test_parentheses_around_one_statement_unwrap
    assert_equal project(normalize(statement("a + b"))), project(normalize(statement("(a + b)")))
  end

  # Value: protects=only one statement unwraps: parentheses around several keep every statement, and empty parentheses stay a node; fails_when=unwrapping drops every statement after the first, or crashes on `()`; why_new=only the one-statement case had a test; seam=none
  # Contract: shape/N4
  def test_parentheses_around_several_statements_or_none_stay_a_node
    assert_equal ["parentheses_node", nil, ["statements_node", nil, ["call_node", "a"], ["call_node", "b"]]],
                 project(normalize(statement("(a; b)")))
    assert_equal ["parentheses_node", nil], project(normalize(statement("()")))
  end

  # Contract: shape/N1
  def test_stimulus_values_in_a_data_hash_survive
    modal = normalize(statement('tag.div data: { controller: "modal", action: "click->modal#open", id: "a" }'))
    dropdown = normalize(statement('tag.div data: { controller: "dropdown", action: "click->modal#open", id: "b" }'))

    refute_equal project(modal), project(dropdown)
    assoc = modal.children.last.children.first.children.first
    assert_equal ["assoc_node", nil,
                  [":literal", nil],
                  ["hash_node", nil,
                   ["assoc_node", nil, [":literal", nil], ["stimulus_value", "modal"]],
                   ["assoc_node", nil, [":literal", nil], ["stimulus_value", "click->modal#open"]],
                   ["assoc_node", nil, [":literal", nil], [":literal", nil]]]],
                 project(assoc)
  end

  # Contract: shape/N1
  def test_stimulus_values_under_dashed_string_keys_survive
    refute_equal project(normalize(statement('link_to "x", path, "data-controller" => "modal"'))),
                 project(normalize(statement('link_to "x", path, "data-controller" => "menu"')))
    assert_equal project(normalize(statement('link_to "x", path, "data-id" => "modal"'))),
                 project(normalize(statement('link_to "x", path, "data-id" => "menu"')))
  end

  # Contract: shape/N1
  # Contract: shape/N3
  def test_bare_identifiers_read_as_locals_only_in_templates
    node = statement("order.title")

    assert_equal ["call_node", "title", ["call_node", "order"]], project(normalize(node))
    assert_equal ["call_node", "title", [":local", nil]],
                 project(Exhale::Dry::Normalizer::Ruby.normalize(node, template: true))
  end

  # Contract: unit/U7
  def test_shapes_end_at_the_last_heredoc_terminator_inside_them
    shape = normalize(statement(<<~RUBY))
      def run
        sql = <<~SQL
          SELECT 1
          FROM x
        SQL
        exec(sql)
      end
    RUBY
    write, call = shape.children.last.children

    assert_equal [2, 5], [write.start_line, write.end_line]
    assert_equal [2, 5], [write.children.first.start_line, write.children.first.end_line]
    assert_equal [6, 6], [call.start_line, call.end_line]
    assert_equal 7, shape.end_line
  end

  # Contract: unit/U7
  def test_a_lambda_ends_at_its_heredoc_terminator
    shape = normalize(statement(<<~RUBY))
      -> { where(<<~SQL) }
        created_at < now()
        AND status = 'open'
      SQL
    RUBY

    assert_equal [1, 4], [shape.start_line, shape.end_line]
  end

  # Contract: shape/N2
  def test_route_helpers_on_a_route_proxy_become_the_marker_too
    assert_equal project(normalize(statement("Rails.application.routes.url_helpers.order_url(o)"))),
                 project(normalize(statement("Rails.application.routes.url_helpers.invoice_url(o)")))
    assert_equal ":route", normalize(statement("main_app.orders_path")).label
    assert_equal ":route", normalize(statement("helpers.edit_order_path(order)")).label
    assert_equal "original_url", normalize(statement("request.original_url")).label
    assert_equal "service_url", normalize(statement("blob.service_url")).label
  end

  # Value: protects=a heredoc with a one-line body, a plain string with no parts, still ends at its terminator; fails_when=only interpolated heredocs, whose parts carry the lines, reach their terminator; why_new=the heredoc tests had multi-line bodies; seam=none
  def test_a_one_line_heredoc_ends_at_its_terminator
    write = normalize(statement("sql = <<~SQL\n  SELECT 1\nSQL\n"))

    assert_equal [1, 3], [write.children.first.start_line, write.children.first.end_line]
  end

  # Value: protects=only a hash under a `data` key reads as Stimulus; any other nested hash makes its values markers; fails_when=every nested hash keeps its controller and action values as names; why_new=the Stimulus tests only nested hashes under data; seam=none
  # Contract: shape/N2
  def test_a_nested_hash_under_another_key_is_not_stimulus
    assert_equal project(normalize(statement('{ meta: { controller: "modal" } }'))),
                 project(normalize(statement('{ meta: { controller: "drawer" } }')))
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
