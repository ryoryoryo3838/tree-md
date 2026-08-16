# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Subtree directives `<!-- hN -->`, `<!-- hN:ID -->`, and `<!-- /hN -->`
  (`N` = 2–6). Markdown headings can only express a *titled* section that runs
  until the next heading of the same or a lower level, so two Forester shapes
  had no source form: a subtree with no `\title`, and content that follows a
  subtree while still belonging to its parent. The opening form carries its own
  level, so a directive-delimited subtree slots into the same level stack that
  headings build and the two forms mix freely; the closing form is only needed
  to return to a parent's body.

- MIT `LICENSE`, verified against the full linked dependency closure (see
  [`DEPENDENCIES.md`](./DEPENDENCIES.md)).
- Complete opam metadata: license, homepage, bug reports, authors, maintainer,
  description, and tags.
- GitHub Actions CI running build, the full test suite, and a check that the
  generated `tree-md.opam` is not stale.
- Japanese README ([`README.ja.md`](./README.ja.md)).

### Changed

- The package version is now declared once, in `dune-project`, and generated
  into `Tree_md.Version.current`. Previously it was hardcoded separately in
  `dune-project`, `lib/cli.ml`, and `lib/manifest.ml`, where a release could
  silently desync the manifest's `compiler` field from the reported version.
- opam dependency constraints are lower bounds (`>=`) expressing the supported
  range, instead of exact pins. Exact reproducibility remains in `dune.lock`,
  which is pinned to OCaml 5.3.0 via `dune-workspace`.
- `alcotest` is now a `with-test` dependency and is no longer forced on
  consumers of the library.
- A tree's body is one ordered sequence of blocks and subtrees rather than a
  block list followed by a subtree list, so a block written after a subtree is
  emitted after it instead of being hoisted above it. Output for every document
  expressible before this release is unchanged.
- An HTML comment whose first word names a subtree directive but does not parse
  (`<!-- H3 -->`, `<!-- h7 -->`, `<!-- /h3:x -->`, `<!-- subtree -->`) is now
  `TM104`. Such comments were silently discarded, which changed the shape of
  the emitted tree with nothing to show for it. Ordinary comments are still
  discarded.
- `<!-- subtree:ID -->` without a space after the colon is now accepted. It
  previously parsed as an ordinary comment, so the identifier was silently
  dropped and the subtree emitted unnamed.
- Subtree directives inside a list item or block quote are now `TM104`. The
  outline is built from the document's own block list, so a nested directive
  was silently discarded.
- A heading with no text is now `TM103`. It used to compile to `\title{}`,
  which is a titled subtree whose title is blank, not an untitled one; untitled
  subtrees now have their own syntax.
- A run of seven or more `#` is now `TM103`. CommonMark reads it as a
  paragraph, so a heading nested one level too deep silently became body text
  with its hashes escaped into the output.

### Removed

- `tree-md.opam.locked`. It duplicated `dune.lock/` while drifting out of step
  with it, leaving it ambiguous which lockfile was authoritative. `dune.lock/`
  is now the single lock artifact; regenerate an opam-native lock with
  `opam lock tree-md.opam` if one is needed.

## [0.1.0]

Initial implementation.

- `tree-md check` and `tree-md build` subcommands, with exit codes 0 (clean),
  1 (source/semantic/forest/generated-state diagnostics), and 2 (usage,
  configuration, manifest, journal, I/O, internal failure).
- Strict `.tree.md` Markdown dialect compiled to deterministic Forester
  `.tree` source, targeting
  `forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be`.
- 26 stable diagnostic codes (`TM001`–`TM500`) with source-span rendering.
- Manifest-owned generated files with SHA-256 manual-modification protection,
  writer locking, and journal-based transactional roll-forward.

[Unreleased]: https://github.com/ryoryoryo3838/tree-md/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ryoryoryo3838/tree-md/releases/tag/v0.1.0
