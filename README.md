# exhale

exhale is the contraction gate for Rails. It fails a pull request while the codebase it leaves behind holds duplicated code the Contract doesn't keep, and it tells the agent doing the cleanup which original each copy should fold into.

Agents duplicate by default. They read the codebase, find a shape that works, and copy it. When pull requests merge without a person reading every diff, the copy reaches main unless a machine stops it, and every session after that copies it again. exhale is that machine for the exhale half of the breath: expand to learn, then contract what you learned into what already exists, in the same PR.

The first check is `exhale dry`. It combines Uncle Bob's [dryer](https://github.com/unclebob/dryer) and Ryan Davis's [flay](https://github.com/seattlerb/flay), rebuilt on [Prism](https://github.com/ruby/prism) and [Herb](https://herb-tools.dev) so it reads modern Ruby and ERB the way Rails writes them.

## Install

```ruby
# Gemfile
group :development, :test do
  gem "exhale", require: false
end
```

```bash
bundle install
bundle binstubs exhale
bin/exhale
```

Exit code 0 means the codebase is clean. 1 means the gate failed: there's unkept duplication, or a Contract clause is stale or names code that doesn't exist. 2 means exhale couldn't run, usually because a file doesn't parse.

## What it compares

Units are methods, the bodies of Rails DSL calls (`scope`, `validate`, callbacks, `before_action` blocks), and ERB templates. Inside each unit it also compares fragments: blocks, conditionals, HTML elements, and runs of three or more consecutive statements lifted out of the middle of a method.

Class-body declarations like `has_many` and `validates` never count, and neither does anything under `db/`, `config/`, `vendor/` or `tmp/`. Tests are left out unless you pass `--include-tests`, because tests should be DAMP, not DRY.

Normalization keeps the names of operations and drops the names of things. Method names at call sites survive, so do operators, HTML tags and Stimulus `data-controller` values. Locals, instance variables, constants, symbols and literals become markers. These two methods are the same shape:

```ruby
def alpha(xs)
  ys = xs.select(&:odd?)
  ys.map(&:succ)
end

def beta(items)
  kept = items.select(&:even?)
  kept.map(&:pred)
end
```

## Scoring

Every subtree of a normalized unit is a fingerprint. Each fingerprint is weighted by how rare it is, `ln(1 + 1000 / count)`, and two units score by Jaccard similarity over those weights. A shape that shows up in every controller weighs close to nothing, so scaffolding doesn't drown out real copies. The default threshold is 0.80, with floors of 4 lines and 20 normalized nodes.

## The gate

Every run sweeps the whole codebase. Main passes the same gate, so anything a pull request trips over is its own doing. exhale compares against the merge base only to label findings:

| Label | Meaning |
| --- | --- |
| Introduced | The PR touched one side, and the pair didn't match at the base |
| Shifted | Neither side was touched, but the PR's changes moved the weights enough to push the pair over |
| Already there | The pair matched at the base too |

The report also lists what the PR contracted: pairs that matched at the base and don't anymore.

An existing app won't sweep clean on its first run. `--introduced-only` gates on introduced and shifted findings and lists the rest as warnings. Once main is clean, drop the flag.

## The Contract

Deliberate duplication is a design decision, so it's declared in the Contract next to its reason. The Contract is organized by primitive, and each kind of analysis has its own file inside the primitive:

```text
contract/
  provider_adapter/
    README.md        the primitive's prose, plus a covers block
    duplication.md   duplication it keeps, why, and its settings
```

A `parallel` block declares units that stay parallel on purpose. Its reason is the section it sits in:

````markdown
## Adapters stay independent

Each provider adapter stays independent. Providers change on their own
schedules, and a shared base class would couple their releases.

```parallel
Payments::*::Adapter
```
````

A `covers` block in the primitive's `README.md` names the code that belongs to it, and a `settings` block in `duplication.md` overrides the defaults for that code:

````markdown
```covers
Payments::*::Adapter
views/payments/**
```

```settings
threshold: 0.75
```
````

A clause that names code that no longer exists fails the gate, and so does a clause with nothing left to keep. The Contract stays true or the build stays red.

## In CI

```yaml
exhale:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: ruby/setup-ruby@v1
      with:
        bundler-cache: true
    - name: exhale
      shell: bash
      run: bin/exhale --base origin/${{ github.base_ref || 'main' }} | tee -a "$GITHUB_STEP_SUMMARY"
```

`fetch-depth: 0` gives exhale the history it needs to find the merge base and run `git blame`. `--format json` prints the same findings as data, and `--format edn` prints them in the shape dryer writes to `.metrics/dry.edn`.

## Determinism

The same commit gets the same verdict on any machine on any day. The verdict reads the commit's tree, its Contract, and the gem versions in its `Gemfile.lock`, and nothing else. Digests are unseeded, weights are fixed-point integers computed without the platform's floating-point log, and every tie breaks on a stable key.

## License

MIT. Copyright Obie Fernandez.
