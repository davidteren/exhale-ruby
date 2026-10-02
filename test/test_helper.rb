# frozen_string_literal: true

# Each test file requires the parts of exhale it exercises, so one component's
# tests never depend on another component loading.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"

module Minitest
  class Test
    def fixture_path(*parts)
      File.join(__dir__, "fixtures", *parts)
    end
  end
end
