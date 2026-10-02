# frozen_string_literal: true

require "test_helper"
require "herb"
require "exhale/dry/normalizer/erb"

class NormalizerErbTest < Minitest::Test
  def test_markup_differing_only_in_values_and_names_is_equal
    edit = normalize(%(<div class="p-4 text-sm"><%= link_to "Edit", edit_order_path(@order) %></div>))
    show = normalize(%(<div class="mt-2 font-bold"><%= link_to "Show", order_path(@invoice) %></div>))

    assert_equal project(edit), project(show)
  end

  def test_stimulus_controller_names_survive
    dropdown = normalize(%(<div data-controller="dropdown"><span></span></div>))
    modal = normalize(%(<div data-controller="modal"><span></span></div>))

    refute_equal project(dropdown), project(modal)
    assert_equal ["html_attribute_value", "dropdown"], project(dropdown.children.first.children.first.children.first)
  end

  def test_stimulus_actions_survive
    refute_equal project(normalize(%(<button data-action="click->menu#open"></button>))),
                 project(normalize(%(<button data-action="click->menu#close"></button>)))
  end

  def test_element_shape
    shape = normalize(%(<DIV class="a"><%= link_to "Edit", edit_order_path(@order) %></DIV>))

    assert_equal ["document_node", nil,
                  ["html_element_node", "div",
                   ["html_attribute_node", "class", [":literal", nil]],
                   ["html_body", nil,
                    ["erb_output", nil,
                     ["call_node", "link_to", ["arguments_node", nil, [":literal", nil], ["call_node", ":route", ["arguments_node", nil, [":ivar", nil]]]]]]]]],
                 project(shape)
    assert shape.sequence
    assert shape.children.first.children.last.sequence
  end

  def test_block_body_is_a_sequence_holding_the_markup
    shape = normalize(%(<% @items.each do |i| %><span><%= i.name %></span><% end %>))
    block = shape.children.first

    assert_equal "erb_block_node", block.kind
    head, body = block.children
    assert_equal ["erb_logic", nil,
                  ["call_node", "each", [":ivar", nil],
                   ["block_node", nil, ["block_parameters_node", nil, ["parameters_node", nil, [":local", nil]]]]]],
                 project(head)
    assert_equal "erb_body", body.kind
    assert body.sequence
    assert_equal ["html_element_node", "span", ["html_body", nil, ["erb_output", nil, ["call_node", "name", [":local", nil]]]]],
                 project(body.children.first)
  end

  def test_text_and_comments_drop_out
    shape = normalize(<<~ERB)
      <%# a comment %>
      <!-- markup comment -->
      Some words
      <p>more words</p>
    ERB

    assert_equal ["document_node", nil, ["html_element_node", "p"]], project(shape)
  end

  def test_if_keeps_conditions_of_every_branch
    shape = normalize(%(<% if admin? %><b></b><% elsif editor? %><i></i><% else %><u></u><% end %>))

    assert_equal ["erb_if_node", nil,
                  ["erb_logic", nil, ["if_node", nil, ["call_node", "admin?"]]],
                  ["erb_body", nil, ["html_element_node", "b"]],
                  ["erb_if_node", nil,
                   ["erb_logic", nil, ["if_node", nil, ["call_node", "editor?"]]],
                   ["erb_body", nil, ["html_element_node", "i"]],
                   ["erb_else_node", nil, ["erb_logic", nil], ["erb_body", nil, ["html_element_node", "u"]]]]],
                 project(shape.children.first)
  end

  def test_case_keeps_its_when_conditions
    shape = normalize(%(<% case state %><% when :draft %><i></i><% end %>))

    assert_equal ["erb_case_node", nil,
                  ["erb_logic", nil, ["call_node", "state"]],
                  ["erb_when_node", nil,
                   ["erb_logic", nil, ["when_node", nil, [":literal", nil]]],
                   ["erb_body", nil, ["html_element_node", "i"]]]],
                 project(shape.children.first)
  end

  def test_yield_keeps_its_arguments
    shape = normalize(%(<%= yield :sidebar %>))

    assert_equal ["erb_yield_node", nil, ["erb_output", nil, ["yield_node", nil, ["arguments_node", nil, [":literal", nil]]]]],
                 project(shape.children.first)
  end

  def test_attribute_values_with_erb_keep_the_erb
    shape = normalize(%(<a class="btn <%= size %>" disabled></a>))

    assert_equal ["html_element_node", "a",
                  ["html_attribute_node", "class",
                   ["html_attribute_value_node", nil, [":literal", nil], ["erb_output", nil, ["call_node", "size"]]]],
                  ["html_attribute_node", "disabled"]],
                 project(shape.children.first)
  end

  def test_template_locals_carry_into_later_tags_until_their_block_ends
    shape = normalize(<<~ERB)
      <% total = 0 %>
      <% rows.each do |row| %><%= row %><%= total %><% end %>
      <%= row %>
    ERB
    block = shape.children[1]
    after = shape.children[2]

    assert_equal [["erb_output", nil, [":local", nil]], ["erb_output", nil, [":local", nil]]],
                 block.children[1].children.map { |child| project(child) }
    assert_equal ["erb_output", nil, ["call_node", "row"]], project(after)
  end

  def test_lines_come_from_the_template
    shape = normalize(<<~ERB)
      <ul>
        <% @items.each do |item| %>
          <li><%= item.name %></li>
        <% end %>
      </ul>
    ERB
    list = shape.children.first
    block = list.children.first.children.first
    head, body = block.children

    assert_equal [1, 5], [list.start_line, list.end_line]
    assert_equal [2, 4], [block.start_line, block.end_line]
    assert_equal [2, 2], [head.start_line, head.end_line]
    assert_equal [3, 3], [body.children.first.start_line, body.children.first.end_line]
    assert_equal 3, body.children.first.children.first.children.first.children.first.start_line
  end

  private

  def normalize(source)
    Exhale::Dry::Normalizer::Erb.normalize(Herb.parse(source, strict: false).value)
  end

  # Shapes compare with their line numbers; this view compares structure.
  def project(shape)
    [shape.kind, shape.label, *shape.children.map { |child| project(child) }]
  end
end
