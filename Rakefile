# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

# The Contract must be met, and contract coverage is published. Every
# obligation in contract/*/README.md needs at least one test that names it
# with a `# Contract: <primitive>/<id>` line, and a tag naming an obligation
# that doesn't exist fails too, so the Contract and the tests can't drift.
desc "Publish contract coverage and fail on any obligation without an executable test"
task :contract do
  obligations = Dir["contract/*/README.md"].sort.flat_map do |path|
    primitive = File.basename(File.dirname(path))
    File.read(path).scan(/^- \*\*([A-Z]+\d+)\*\*/).flatten.map { |id| "#{primitive}/#{id}" }
  end
  tags = {}
  Dir["test/**/*_test.rb"].sort.each do |file|
    File.foreach(file).with_index(1) do |line, number|
      next unless (match = line.match(%r{#\s*Contract:\s*([a-z]+/[A-Z]+\d+)}))

      (tags[match[1]] ||= []) << "#{file}:#{number}"
    end
  end

  obligations.each do |id|
    tests = tags.fetch(id, [])
    puts "#{tests.empty? ? 'MISSING' : 'ok     '} #{id.ljust(16)} #{tests.size} test#{'s' unless tests.size == 1}"
  end
  covered = obligations.count { |id| tags.key?(id) }
  puts "contract coverage: #{covered}/#{obligations.size} obligations (#{(100.0 * covered / obligations.size).round}%)"

  unknown = tags.keys - obligations
  abort "tests name obligations the Contract doesn't have: #{unknown.sort.join(', ')}" unless unknown.empty?
  missing = obligations.reject { |id| tags.key?(id) }
  abort "obligations with no executable test: #{missing.join(', ')}" unless missing.empty?
end

task default: %i[test contract]

# Release tooling, the single-gem shape of the terret repo's rake release
# tasks. The gemspec is the one source of name and version; nothing here
# hardcodes either. The release workflow drives these three tasks in order.
namespace :release do
  gemspec = -> { Gem::Specification.load(Dir["*.gemspec"].first) }

  published = lambda do |spec|
    require "open-uri"
    require "json"
    body = URI.open("https://rubygems.org/api/v1/versions/#{spec.name}.json", &:read)
    JSON.parse(body).any? { |v| v["number"] == spec.version.to_s }
  rescue OpenURI::HTTPError
    false # 404 => the gem has never been published, so there is nothing to skip
  end

  desc "Build the gem into pkg/ with --strict (proof the gemspec is valid). " \
       "Reversible, pkg/ is gitignored, and the local half of a release; " \
       "release:push is the irreversible half."
  task :build do
    require "fileutils"
    spec = gemspec.call
    FileUtils.rm_rf("pkg")
    FileUtils.mkdir_p("pkg")
    # --strict escalates any spec warning to a build failure.
    sh "gem build #{File.basename(spec.loaded_from)} --strict --output pkg/#{spec.name}-#{spec.version}.gem"
  end

  desc "Print publish=true when the gemspec's version is not yet on RubyGems " \
       "and publish=false when it is. The release workflow reads this to decide " \
       "whether to fetch credentials and push at all."
  task :status do
    puts "publish=#{!published.call(gemspec.call)}"
  end

  desc "Push pkg/<gem>-<version>.gem to RubyGems. A version already published " \
       "is skipped, so a re-run is safe. The release workflow runs this with a " \
       "short-lived key from trusted publishing; by hand it needs RubyGems MFA."
  task :push do
    spec = gemspec.call
    gem_file = "pkg/#{spec.name}-#{spec.version}.gem"
    abort "release:push: #{gem_file} is missing, run `rake release:build` first" unless File.exist?(gem_file)

    if published.call(spec)
      puts "skip  #{spec.name} #{spec.version} (already on RubyGems)"
      next
    end

    puts "push  #{gem_file}"
    sh "gem push #{gem_file}"
  end
end
