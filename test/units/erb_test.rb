# frozen_string_literal: true

require "test_helper"
require "exhale/units/erb"

class UnitsErbTest < Minitest::Test
  SOURCE = <<~ERB
    <%= form_with model: @order do |f| %>
      <%= f.text_field :total %>
    <% end %>
  ERB

  # Contract: unit/U8
  def test_a_template_is_one_unit
    units = Exhale::Units::Erb.extract(SOURCE, "app/views/orders/_form.html.erb")

    assert_equal 1, units.size
    unit = units.first
    assert_equal :template, unit.kind
    assert_equal "views/orders/_form.html.erb", unit.identity
    assert_nil unit.namespace
    assert_nil unit.name
    assert_equal "app/views/orders/_form.html.erb", unit.path
    assert_equal :erb, unit.language
    assert_equal [1, 3], [unit.start_line, unit.end_line]
    assert_instance_of Herb::AST::DocumentNode, unit.node
  end

  # Contract: unit/U8
  def test_identity_keeps_paths_outside_app
    unit = Exhale::Units::Erb.extract("<p></p>\n", "engines/shop/views/a.html.erb").first

    assert_equal "engines/shop/views/a.html.erb", unit.identity
  end

  def test_omitted_close_tags_are_valid_html
    assert_equal 1, Exhale::Units::Erb.extract("<ul><li>a<li>b</ul>\n", "app/views/a.html.erb").size
  end

  # Contract: unit/U9
  def test_unclosed_tag_raises
    error = assert_raises(Exhale::ParseError) do
      Exhale::Units::Erb.extract("<p>fine</p>\n<div>\n  <span>x</span>\n", "app/views/orders/show.html.erb")
    end

    assert_equal "app/views/orders/show.html.erb", error.path
    assert_equal 2, error.line
  end

  # Contract: unit/U9
  def test_unclosed_erb_block_raises
    assert_raises(Exhale::ParseError) do
      Exhale::Units::Erb.extract("<% items.each do |i| %>\n  <%= i %>\n", "app/views/a.html.erb")
    end
  end

  # Contract: unit/U9
  def test_broken_ruby_raises
    assert_raises(Exhale::ParseError) { Exhale::Units::Erb.extract("<%= link_to( %>\n", "app/views/a.html.erb") }
  end
end
