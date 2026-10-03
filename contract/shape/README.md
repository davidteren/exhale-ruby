# Shape

Shape is the normalized tree. Normalization keeps the names of operations and replaces the names of things with markers, so code that does the same thing to different data produces the same shape.

## Obligations

- **N1** The names of operations survive: method names at call sites, bare calls Prism marks as variable calls in Ruby files, operators, `.new`, HTML tag and attribute names, and Stimulus `data-controller` and `data-action` values, in attribute form and in Ruby hash form.
- **N2** The names of things become markers: locals, instance and class variables, constants, symbols, hash keys, literals, and route helpers: calls ending in `_path` or `_url` made bare or through `url_helpers`, `main_app`, `helpers` or `routes`. The same names on any other receiver stay calls.
- **N3** In a template, a bare identifier with no receiver, arguments or block is a local, so two partials that differ only in their locals' names have the same shape.
- **N4** Text, whitespace and comments are dropped. Control flow and block structure are kept.
- **N5** A shape depends only on the source it came from.

```covers
Exhale::Dry::Normalizer
```
