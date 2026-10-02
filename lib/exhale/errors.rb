# frozen_string_literal: true

module Exhale
  class Error < StandardError; end

  # An error that points at a line in a file.
  class LocatedError < Error
    attr_reader :path, :line

    def initialize(path, line, message)
      @path = path
      @line = line
      super("#{path}:#{line}: #{message}")
    end
  end

  # A Ruby or ERB file the parser reported errors for. The gate never passes
  # code it couldn't read, so the CLI turns this into exit code 2.
  class ParseError < LocatedError; end

  # A problem in the Contract that makes it unusable as written: an empty
  # block, a reference that resolves to nothing, a malformed settings block.
  class ContractError < LocatedError; end

  # git failed in a way exhale can't work around.
  class GitError < Error; end
end
