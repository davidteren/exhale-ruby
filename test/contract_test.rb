# frozen_string_literal: true

require "test_helper"
require "contract_helper"

class ContractParseTest < ContractTestCase
  def test_missing_dir_is_empty
    c = load_contract
    assert_empty c.primitives
    assert_empty c.clauses
    assert_empty c.errors
    assert_equal({}, c.settings)
  end

  def test_loose_files_at_root_ignored
    write "contract/notes.md", "```parallel\nA::B\n```\n"
    write "contract/p/README.md", "hi"
    c = load_contract
    assert_empty c.clauses
    assert_equal ["p"], c.primitives.map(&:name)
  end

  def test_custom_dir
    write "docs/c/p/duplication.md", "```parallel\nA\n```\n"
    c = Exhale::Contract.load(@root, dir: "docs/c")
    assert_equal "docs/c/p/duplication.md", c.clauses.first.path
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
  def test_parses_settings
    write "contract/p/duplication.md", "```settings\nthreshold: 0.75\nmin-lines: 3\nmin-nodes: 10\n```\n"
    c = load_contract
    assert_equal({ threshold: 0.75, min_lines: 3, min_nodes: 10 }, c.settings["p"])
    assert_empty c.errors
  end

  def test_only_given_keys
    write "contract/p/duplication.md", "```settings\nmin-lines: 3\n```\n"
    assert_equal({ min_lines: 3 }, load_contract.settings["p"])
  end

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

  def test_threshold_one_ok
    write "contract/p/duplication.md", "```settings\nthreshold: 1\n```\n"
    assert_equal({ threshold: 1.0 }, load_contract.settings["p"])
  end

  def test_two_settings_blocks
    write "contract/p/duplication.md", "```settings\nmin-lines: 3\n```\n\n```settings\nmin-lines: 4\n```\n"
    c = load_contract
    assert_equal 1, c.errors.size
    assert_equal 5, c.errors.first.line
    assert_equal({ min_lines: 3 }, c.settings["p"])
  end
end
