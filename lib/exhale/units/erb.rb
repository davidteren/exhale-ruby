# frozen_string_literal: true

require "herb"
require_relative "../errors"
require_relative "../unit"

module Exhale
  module Units
    # A template is one unit. Duplication inside it is found later, as
    # fragments of its tree.
    module Erb
      module_function

      def extract(source, path)
        # strict: false lets valid HTML through (an omitted `</li>`); broken
        # markup and broken Ruby are still errors.
        result = Herb.parse(source, strict: false)
        raise_first_error(result.errors, path) unless result.errors.empty?

        [Unit.new(kind: :template, identity: path.delete_prefix("app/"), namespace: nil, name: nil, path: path,
                  start_line: 1, end_line: [source.lines.size, 1].max, language: :erb, node: result.value)]
      end

      def raise_first_error(errors, path)
        error = errors.min_by { |e| [e.location.start.line, e.location.start.column] }
        raise ParseError.new(path, error.location.start.line, error.message)
      end
    end
  end
end
