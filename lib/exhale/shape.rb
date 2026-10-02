# frozen_string_literal: true

module Exhale
  # One node of a normalized tree. Normalization keeps the names of
  # operations and the shape of the tree, and replaces the names of things
  # with markers, so two units that do the same thing to different locals
  # produce equal trees.
  #
  # kind       - String. A Prism or Herb node type after normalization
  #              ("call_node", "if_node", "html_element_node"), or a marker
  #              for a dropped name: ":local", ":ivar", ":cvar", ":gvar",
  #              ":const", ":literal".
  # label      - String or nil. A name normalization keeps: the method name at
  #              a call site (operators are calls too), an HTML tag name, an
  #              attribute name, or a kept attribute value (data-controller,
  #              data-action).
  # children   - Array of Shape, in source order.
  # start_line - 1-based first line in the unit's file.
  # end_line   - 1-based last line.
  # sequence   - true when children are a run of statements or sibling
  #              markup (a method body, a block body, an element's children).
  #              Statement-run fragments come only from sequences.
  Shape = Struct.new(:kind, :label, :children, :start_line, :end_line, :sequence, keyword_init: true) do
    def leaf?
      children.empty?
    end

    def lines
      end_line - start_line + 1
    end
  end
end
