# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
