# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "exhale/shape"
require "exhale/unit"
require "exhale/units/ruby"
require "exhale/units/erb"
require "exhale/dry/normalizer"

# Shape's N5 (contract/shape/README.md): a shape depends only on the source
# it came from, never on what ran before it or on the process around it.
class ShapeContractTest < Minitest::Test
  FILES = {
    "app/models/café.rb" => <<~'RUBY',
      class Café
        def total(lines)
          naïve = lines.sum { |l| l.amount * l.quantity }
          stamp = Time.now.strftime("%Y-%m-%d")
          "#{naïve} à #{stamp}".encode("UTF-8")
        end
      end
    RUBY
    "app/views/orders/_form.html.erb" => <<~'ERB'
      <%# locals: (order:, compact: false) %>
      <div data-controller="modal" class="p-4">
        <% order.lines.each do |line| %>
          <p>Prix : <%= number_to_currency(line.amount) %> – <%= l(line.created_at) %></p>
        <% end %>
      </div>
    ERB
  }.freeze

  # Run in this process and in a child process with another environment.
  SCRIPT = <<~'RUBY'
    require "exhale/units/ruby"
    require "exhale/units/erb"
    require "exhale/dry/normalizer"
    root = ARGV.fetch(0)
    shapes = ARGV.drop(1).map do |path|
      source = File.read(File.join(root, path), encoding: "UTF-8")
      units = path.end_with?(".erb") ? Exhale::Units::Erb.extract(source, path) : Exhale::Units::Ruby.extract(source, path)
      units.map { |unit| [unit.identity, Exhale::Dry::Normalizer.normalize(unit)] }
    end
    $stdout.binmode
    $stdout.write([Marshal.dump(shapes)].pack("m0"))
  RUBY

  def setup
    @root = Dir.mktmpdir("exhale-shape")
    FILES.each do |path, source|
      full = File.join(@root, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, source, encoding: "UTF-8")
    end
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def shapes_in(env)
    lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", SCRIPT, @root, *FILES.keys)
    assert status.success?, err
    Marshal.load(out.unpack1("m0")) # rubocop:disable Security/MarshalLoad
  end

  def normalize_here
    FILES.keys.map do |path|
      source = File.read(File.join(@root, path), encoding: "UTF-8")
      units = path.end_with?(".erb") ? Exhale::Units::Erb.extract(source, path) : Exhale::Units::Ruby.extract(source, path)
      units.map { |unit| [unit.identity, Exhale::Dry::Normalizer.normalize(unit)] }
    end
  end

  # Contract: shape/N5
  def test_normalizing_the_same_source_twice_gives_equal_shapes
    first = normalize_here
    second = normalize_here

    refute_empty first.flatten(1)
    assert_equal first, second
  end

  # Normalizers keep state while they walk (the ERB walker's local scopes).
  # None of it may leak from one unit into the next.
  # Contract: shape/N5
  def test_a_shape_does_not_depend_on_what_was_normalized_before_it
    template = FILES.keys.find { |path| path.end_with?(".erb") }
    source = File.read(File.join(@root, template), encoding: "UTF-8")
    fresh = Exhale::Dry::Normalizer.normalize(Exhale::Units::Erb.extract(source, template).first)

    other = %(<%# locals: (line:) %>\n<% [1].each do |order| %><%= order %><% end %>\n)
    Exhale::Dry::Normalizer.normalize(Exhale::Units::Erb.extract(other, "app/views/x/_y.html.erb").first)
    after = Exhale::Dry::Normalizer.normalize(Exhale::Units::Erb.extract(source, template).first)

    assert_equal fresh, after
  end

  # Contract: shape/N5
  def test_locale_and_time_zone_do_not_change_a_shape
    utc = shapes_in("LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8", "TZ" => "UTC")
    c_locale = shapes_in("LANG" => "C", "LC_ALL" => "C", "TZ" => "Asia/Kathmandu")

    refute_empty utc.flatten(1)
    assert_equal utc, c_locale
    assert_equal normalize_here, utc
  end
end
