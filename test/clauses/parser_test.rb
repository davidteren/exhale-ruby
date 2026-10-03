# frozen_string_literal: true

require "test_helper"
require "clauses/clauses_helper"

class ContractParseTest < ContractTestCase
  def test_missing_dir_is_empty
    c = load_contract
    assert_empty c.primitives
    assert_empty c.clauses
    assert_empty c.errors
    assert_equal({}, c.settings)
  end

  # Contract: clause/C1
  def test_loose_files_at_root_ignored_unless_they_hold_contract_blocks
    write "contract/notes.md", "just prose\n```ruby\nx\n```\n"
    write "contract/p/README.md", "hi"
    c = load_contract
    assert_empty c.clauses
    assert_empty c.errors
    assert_equal ["p"], c.primitives.map(&:name)
  end

  # Value: protects=a Contract file that isn't valid UTF-8 is reported as an error against that file; fails_when=the file is parsed anyway and the load raises instead of reporting; why_new=no test fed the Contract a non-UTF-8 file; seam=none
  # Contract: clause/C1
  def test_a_contract_file_that_is_not_utf8_is_an_error
    path = File.join(@root, "contract/p/README.md")
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, "caf\xE9\n```covers\nA\n```\n".b)
    c = load_contract
    assert_equal ["contract/p/README.md:1"], c.errors.map { |e| "#{e.path}:#{e.line}" }
    assert_match(/not valid UTF-8/, c.errors.first.message)
  end

  # Contract: clause/C1
  def test_contract_block_at_root_is_error
    write "contract/notes.md", "x\n```parallel\nA::B\n```\n"
    c = load_contract
    assert_empty c.clauses
    assert_equal ["contract/notes.md:2"], c.errors.map { |e| "#{e.path}:#{e.line}" }
    assert_match(/primitive directory/, c.errors.first.message)
  end

  # Contract: clause/C1
  def test_parallel_and_settings_in_readme_are_errors
    write "contract/p/README.md", "```parallel\nA\n```\n```settings\nmin-lines: 2\n```\n"
    c = load_contract
    assert_empty c.clauses
    assert_equal({}, c.settings)
    assert_equal [1, 4], c.errors.map(&:line)
    assert(c.errors.all? { |e| e.message.include?("duplication.md") })
  end

  # Contract: clause/C1
  def test_covers_in_duplication_is_error
    write "contract/p/duplication.md", "```covers\nA\n```\n"
    write "contract/p/duplication/x.md", "```covers\nB\n```\n"
    c = load_contract
    assert_equal 2, c.errors.size
    assert(c.errors.all? { |e| e.message.include?("README.md") })
    assert_empty c.primitives.first.covers
  end

  # Contract: clause/C6
  def test_fences_in_html_comments_are_dead
    write "contract/p/duplication.md", "<!--\n```parallel\nA\n```\n-->\n<!-- ```x -->\n```parallel\nB\n```\n"
    c = load_contract
    assert_equal [%w[B]], c.clauses.map { |cl| cl.references.map(&:text) }
    assert_empty c.errors
  end

  # Contract: clause/C5
  def test_repeated_setting_key_is_error
    write "contract/p/duplication.md", "```settings\nthreshold: 0.9\nthreshold: 0.5\n```\n"
    c = load_contract
    assert_equal [3], c.errors.map(&:line)
    assert_equal({ threshold: 0.9 }, c.settings["p"])
  end

  # Contract: clause/C1
  def test_custom_dir
    write "docs/c/p/duplication.md", "```parallel\nA\n```\n"
    c = Exhale::Contract.load(@root, dir: "docs/c")
    assert_equal "docs/c/p/duplication.md", c.clauses.first.path
  end

  # Value: protects=clauses are listed by path, then line, whatever order the primitives' directories were read in; fails_when=clauses come in directory order, so `billing` lists before `billing-v2` though its path sorts after; why_new=every ordering test used one primitive or names whose two orders agree; seam=none
  def test_clauses_are_listed_by_path_then_line
    write "contract/billing/duplication.md", "# one\n\n```parallel\nA\nB\n```\n"
    write "contract/billing-v2/duplication.md", "# two\n\n```parallel\nC\nD\n```\n"

    assert_equal %w[contract/billing-v2/duplication.md contract/billing/duplication.md], load_contract.clauses.map(&:path)
  end

  def test_covers_block
    write "contract/p/README.md", "# P\n\n```covers\nA::B\nA::B#go # why\n```\n"
    covers = load_contract.primitives.first.covers
    assert_equal ["A::B", "A::B#go"], covers.map(&:text)
    assert_equal [4, 5], covers.map(&:line)
    assert_equal "contract/p/README.md", covers.first.path
  end

  def test_fence_styles
    write "contract/p/duplication.md", <<~MD
      ```parallel
      A
      ```

      ~~~parallel
      B
      ~~~

      ````parallel
      C
      ```
      still C
      ````

         ```parallel
         D
         ```

          ```parallel
          not a fence (4 spaces)
          ```
    MD
    c = load_contract
    assert_equal [%w[A], %w[B], ["C", "```", "still C"], %w[D]], c.clauses.map { |cl| cl.references.map(&:text) }
  end

  def test_other_info_strings_ignored_and_closing_needs_same_char
    write "contract/p/duplication.md", <<~MD
      ```ruby
      Foo
      ```
      ~~~parallel
      A
      ```
      B
      ~~~
      ```text
      x
      ```
    MD
    c = load_contract
    assert_equal 1, c.clauses.size
    assert_equal %w[A ``` B], c.clauses.first.references.map(&:text)
  end

  def test_nested_longer_fence_with_backticks_inside
    write "contract/p/duplication.md", "````parallel\nA\n```ruby\nB\n```\n````\n"
    assert_equal %w[A ```ruby B ```], load_contract.clauses.first.references.map(&:text)
  end

  # Contract: clause/C1
  def test_reason_and_heading
    write "contract/p/duplication.md", <<~MD
      # Top

      ## Providers are siblings

      Each provider has
      its own   adapter.

      ```ruby
      ignored
      ```

      More words.

      ```parallel
      A
      ```
    MD
    cl = load_contract.clauses.first
    assert_equal "Providers are siblings", cl.heading
    assert_equal "Providers are siblings Each provider has its own adapter. More words.", cl.reason
    assert_equal 14, cl.line
    assert_equal "p", cl.primitive
    assert_equal :parallel, cl.kind
  end

  # Contract: clause/C1
  def test_reason_resets_after_each_block
    write "contract/p/duplication.md", "## H\nreasonA\n```parallel\nA\n```\nreasonB\n```parallel\nB\n```\n"
    assert_equal ["H reasonA", "H reasonB"], load_contract.clauses.map(&:reason)
  end

  # Contract: clause/C1
  def test_setext_headings
    write "contract/p/duplication.md", "Title\n=====\n\n```parallel\nA\n```\nSub\n---\nwhy\n```parallel\nB\n```\n"
    cl = load_contract.clauses
    assert_equal ["Title", "Sub"], cl.map(&:heading)
    assert_equal ["Title", "Sub why"], cl.map(&:reason)
  end

  # Value: protects=a `---` line only underlines the prose directly above it, so a thematic break after a blank line leaves the heading alone; fails_when=the prose flag outlives the blank line and the break turns the last prose line into the clause's heading; why_new=setext tests put the underline directly under its title; seam=none
  # Contract: clause/C1
  def test_a_break_after_a_blank_line_is_not_a_setext_underline
    write "contract/p/duplication.md", "## Real heading\n\nSome prose.\n\n---\n\n```parallel\nA\n```\n"
    assert_equal ["Real heading"], load_contract.clauses.map(&:heading)
  end

  # Value: protects=a fence left open runs to the end of the file, as CommonMark has it; fails_when=an unclosed block at the end of the file is dropped and its clause disappears; why_new=every fence test closed its fences; seam=none
  def test_an_unclosed_fence_runs_to_the_end_of_the_file
    write "contract/p/duplication.md", "## Kept\n\n```parallel\nA\nB\n"
    assert_equal [%w[A B]], load_contract.clauses.map { |cl| cl.references.map(&:text) }
  end

  # Value: protects=a backtick fence whose info string holds a backtick isn't a fence, as CommonMark has it; fails_when=such a line opens a parallel block; why_new=no info string held a backtick; seam=none
  def test_a_backtick_in_a_backtick_info_string_opens_no_fence
    write "contract/p/duplication.md", "## H\n\n```parallel `x`\nA\nB\n```\n"
    assert_empty load_contract.clauses
  end

  def test_no_heading
    write "contract/p/duplication.md", "Just prose.\n```parallel\nA\n```\n"
    cl = load_contract.clauses.first
    assert_nil cl.heading
    assert_equal "Just prose.", cl.reason
  end

  def test_trailing_comments_vs_method_refs
    write "contract/p/duplication.md", <<~MD
      ```parallel
      Payments::*::Adapter   # the providers
      A::B#charge
      A::B.run #
      # whole line comment
      A::C#x #note
      ```
    MD
    texts = load_contract.clauses.first.references.map(&:text)
    assert_equal ["Payments::*::Adapter", "A::B#charge", "A::B.run", "A::C#x #note"], texts
  end

  # Contract: clause/C3
  def test_empty_block_is_error
    write "contract/p/duplication.md", "x\n```parallel\n\n  # nothing\n```\n"
    c = load_contract
    assert_empty c.clauses
    assert_equal 1, c.errors.size
    assert_equal 2, c.errors.first.line
    assert_kind_of Exhale::ContractError, c.errors.first
  end

  def test_key_is_stable_and_order_independent
    write "contract/p/duplication.md", "```parallel\nB\nA\n```\n"
    write "contract/q/duplication.md", "```parallel\nB\nA\n```\n"
    k1, k2 = load_contract.clauses.map(&:key)
    assert_match(/\A\h{64}\z/, k1)
    refute_equal k1, k2
    require "digest"
    assert_equal Digest::SHA256.hexdigest("p|parallel|A\nB"), k1
  end

  # Contract: clause/C1
  def test_duplication_directory_form
    write "contract/p/duplication/b.md", "```parallel\nB\n```\n"
    write "contract/p/duplication/sub/a.md", "```parallel\nA\n```\n"
    write "contract/p/duplication/skip.txt", "```parallel\nZ\n```\n"
    c = load_contract
    assert_equal %w[contract/p/duplication/b.md contract/p/duplication/sub/a.md], c.clauses.map(&:path)
  end

  def test_clauses_sorted_by_path_then_line
    write "contract/z/duplication.md", "```parallel\nZ\n```\n"
    write "contract/a/duplication.md", "```parallel\nA\n```\n\n```parallel\nA2\n```\n"
    assert_equal %w[A A2 Z], load_contract.clauses.map { |c| c.references.first.text }
  end
end

class ContractSettingsTest < ContractTestCase
  # Contract: clause/C5
  def test_parses_settings
    write "contract/p/duplication.md", "```settings\nthreshold: 0.75\nmin-lines: 3\nmin-nodes: 10\n```\n"
    c = load_contract
    assert_equal({ threshold: 0.75, min_lines: 3, min_nodes: 10 }, c.settings["p"])
    assert_empty c.errors
  end

  # Contract: clause/C5
  def test_only_given_keys
    write "contract/p/duplication.md", "```settings\nmin-lines: 3\n```\n"
    assert_equal({ min_lines: 3 }, load_contract.settings["p"])
  end

  # Contract: clause/C5
  def test_bad_settings
    write "contract/p/duplication.md", <<~MD
      ```settings
      threshold: 0
      threshold: 1.5
      threshold: abc
      min-lines: 0
      min-lines: 2.5
      min-nodes: x
      bogus: 1
      ```
    MD
    c = load_contract
    assert_equal 7, c.errors.size
    assert_equal [2, 3, 4, 5, 6, 7, 8], c.errors.map(&:line)
    assert_equal({}, c.settings["p"])
  end

  # Contract: clause/C5
  def test_threshold_one_ok
    write "contract/p/duplication.md", "```settings\nthreshold: 1\n```\n"
    assert_equal({ threshold: 1.0 }, load_contract.settings["p"])
  end

  # Contract: clause/C5
  def test_blank_and_comment_lines_in_settings_are_not_settings
    write "contract/p/duplication.md", "```settings\n# floors for the billing code\nmin-lines: 3\n\nmin-nodes: 10\n```\n"
    c = load_contract
    assert_equal({ min_lines: 3, min_nodes: 10 }, c.settings["p"])
    assert_empty c.errors
  end

  # Contract: clause/C5
  def test_floors_of_one_ok
    write "contract/p/duplication.md", "```settings\nmin-lines: 1\nmin-nodes: 1\n```\n"
    c = load_contract
    assert_equal({ min_lines: 1, min_nodes: 1 }, c.settings["p"])
    assert_empty c.errors
  end

  # Contract: clause/C5
  def test_two_settings_blocks
    write "contract/p/duplication.md", "```settings\nmin-lines: 3\n```\n\n```settings\nmin-lines: 4\n```\n"
    c = load_contract
    assert_equal 1, c.errors.size
    assert_equal 5, c.errors.first.line
    assert_equal({ min_lines: 3 }, c.settings["p"])
  end
end

class ContractContainmentTest < ContractTestCase
  def link(target, rel)
    path = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.symlink(target, path)
  end

  def outside
    @outside ||= Dir.mktmpdir.tap { |d| File.write(File.join(d, "x.md"), "```parallel\nA\n```\n") }
  end

  def teardown
    FileUtils.remove_entry(@outside) if @outside
    super
  end

  # Contract: clause/C1
  def test_symlinked_duplication_file_is_error_and_not_read
    write "contract/p/README.md", "hi"
    link File.join(outside, "x.md"), "contract/p/duplication.md"
    c = load_contract
    assert_empty c.clauses
    assert_equal ["contract/p/duplication.md"], c.errors.map(&:path)
    assert_match(/symlink/, c.errors.first.message)
  end

  # Contract: clause/C1
  def test_symlinked_primitive_directory_is_error_and_not_read
    link outside, "contract/p"
    File.write(File.join(outside, "duplication.md"), "```parallel\nA\n```\n")
    c = load_contract
    assert_empty c.clauses
    assert_empty c.primitives
    assert_equal ["contract/p"], c.errors.map(&:path)
  end

  # Contract: clause/C1
  def test_symlinked_duplication_directory_and_nested_link_are_errors
    write "contract/p/README.md", "hi"
    link outside, "contract/p/duplication"
    write "contract/q/duplication/a.md", "```parallel\nB\n```\n"
    link File.join(outside, "x.md"), "contract/q/duplication/b.md"
    c = load_contract
    assert_equal %w[B], c.clauses.map { |cl| cl.references.first.text }
    assert_equal %w[contract/p/duplication contract/q/duplication/b.md], c.errors.map(&:path).sort
  end

  # Contract: clause/C1
  def test_symlinked_contract_directory_is_error
    link outside, "contract"
    c = load_contract
    assert_empty c.primitives
    assert_equal 1, c.errors.size
  end

  # Contract: clause/C1
  def test_block_in_other_markdown_inside_primitive_is_error
    write "contract/p/README.md", "hi"
    write "contract/p/notes.md", "x\n```parallel\nA\n```\n"
    write "contract/p/sub/more.md", "```covers\nA\n```\n"
    write "contract/p/other.md", "```ruby\nfine\n```\n"
    c = load_contract
    assert_empty c.clauses
    assert_equal [["contract/p/notes.md", 2], ["contract/p/sub/more.md", 1]], c.errors.map { |e| [e.path, e.line] }
  end

  # Contract: clause/C1
  def test_contract_files_read_as_utf_8_under_ascii_locale
    write "contract/p/duplication.md", "## Café adapters\n\n```parallel\nA\n```\n"
    saved = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII
    c = load_contract
    assert_equal "Café adapters", c.clauses.first.heading
  ensure
    Encoding.default_external = saved
  end
end
