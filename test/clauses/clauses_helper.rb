# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "exhale/contract"

class ContractTestCase < Minitest::Test
  def setup
    @root = Dir.mktmpdir
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def write(rel, content)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def load_contract
    Exhale::Contract.load(@root)
  end

  def unit(identity, kind: :method, path: "app/x.rb", line: 1)
    ns = nil
    name = nil
    unless kind == :template
      ns, name = identity.split(/[#.]/, 2)
    end
    Exhale::Unit.new(kind: kind, identity: identity, namespace: ns, name: name, path: path,
                     start_line: line, end_line: line + 2, language: kind == :template ? :erb : :ruby)
  end

  def cunit(namespace, name = "m", path: "app/c.rb")
    Exhale::Unit.new(kind: :method, identity: "#{namespace}##{name}", namespace: namespace, name: name,
                     path: path, start_line: 1, end_line: 3, language: :ruby)
  end

  def resolver(units)
    Exhale::Contract::Resolver.new(load_contract, units)
  end
end

