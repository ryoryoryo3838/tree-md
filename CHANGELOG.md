# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `[publish].from` in `tree-md.toml` names the trees a build starts from, as
  globs relative to a source root; everything those reach transitively comes
  with them. A whole Obsidian vault can then be the source without the whole
  vault becoming the site: a published page may link to a note kept anywhere,
  and that note is published because it is linked to. An unpublished note is
  not compiled at all — not emitted, and not reported on, so a draft with a
  broken link cannot fail the build for the pages that do not carry it — and
  the count appears in the build summary so that one you meant to publish and
  forgot to link does not vanish in silence. A source the pattern names is
  compiled even if it does not parse, and a reference landing on an address
  two trees share pulls in both, so the collision is `TM201` rather than
  decided by which path sorts first. Minting follows publication. Without the
  table every source is published, as before.

  A `from` that matches no source at all is a `TM401` warning rather than a
  silent success. Patterns are matched below the source root, with the root
  itself already spent, so one written against a layout the sources are not in
  selects nothing — and a build that publishes nothing emits no tree and
  deletes every tree it wrote before, which otherwise looks exactly like a
  build with nothing to do.

- tree-md reads what a collection declares as an
  [mdbase](https://github.com/mdbase-dev/mdbase-spec) v0.3.0 collection.
  `mdbase.yaml` supplies `settings.validation` (the severity a schema
  violation is reported at, or `off`), `settings.types_folder`,
  `settings.id_field` (which key holds a tree's address, read *and* written by
  minting) and `settings.explicit_type_keys`. Type files under the types
  folder pair a `match` rule with a JSON Schema; the schema validates the front
  matter as written, and `collection.read_defaults` then supplies a value for
  each key a record leaves missing, writing nothing back to the note. A
  violation carries mdbase's canonical code beside tree-md's own, as
  `TM101 (schema_enum)`. Nothing is required: a forest with neither file
  behaves exactly as it did before they existed.

  The JSON Schema profile is exactly the required list of mdbase §06, and a
  keyword outside it makes the schema fail to compile rather than being
  ignored when a record is validated. The same rule governs a type file's own
  sections: `collection.unique`, `collection.links`, `lifecycle` and the rest
  are refused with a message saying what tree-md does instead, because a type
  that silently means less than it says is worse than one that will not load.

- Front matter is an arbitrary mapping, as mdbase v0.3 §03 defines it. A key
  `tree-md` does not interpret is carried and emitted nowhere instead of being
  a `TM101`, so the `aliases`, `cssclasses`, `created` and `publish` an
  Obsidian vault is full of no longer stop a file from compiling. A key within
  an edit or two of one it does know — `taxo:` for `taxon:` — is still
  reported, now as a warning, because dropping that one in silence would lose
  a `\taxon{}` with nothing to show for it. A key in mdbase's `x-` extension
  namespace is never treated as a misspelling.

- `tags`, `authors` and `contributors` accept a single bare scalar as well as
  a list, which is how Obsidian writes one of something.

- Markdown constructs that HTML has a standard element for now compile,
  through Forester's html namespace, instead of being `TM102`: GFM tables
  (`\<html:table>`, alignment as a cell style), `~~strikethrough~~`
  (`\<html:del>`), task-list items (a disabled `\<html:input>` checkbox), and
  Obsidian's `==highlight==` (`\<html:mark>`). `%%comment%%` is discarded, as
  an HTML comment already was; a paragraph that held nothing else leaves no
  `\p{}` behind. A delimiter inside a code span is never one.

- Obsidian callouts. `> [!note] Title` becomes
  `\<html:blockquote>[class]{callout}[data-callout]{note}{…}` with the title in
  its own div — Obsidian's own markup, so a stylesheet written for one renders
  the other. It used to emit a literal `[!note]` into the body.

- Footnotes. A reference becomes a superscript link and the definitions are
  gathered into an ordered list at the end of the tree with a link back.
  Numbering follows the order references first appear, not the order
  definitions do, so moving a definition renumbers nothing. A definition
  nothing refers to is dropped. The section is placed in the note's own body,
  closing any subtree that was still open.

- `![[diagram.png]]` embeds an attachment rather than transcluding a tree,
  settled by the extension. Obsidian writes just the file name, so a
  destination carrying no `/` is searched for by name under the asset roots;
  several matches is `TM204` and says to write the path instead. Obsidian's
  `![[x.png|300]]` sets the width, and a non-numeric alias is the alt text.

- A Markdown link whose destination is not a URL is offered to resolution, so
  `[see](note.md)` emits the identity `note` resolves to instead of an address
  no tree has. Only a wiki link is closed-world: a destination beginning with
  `/` names the published site and is never a tree reference, and one that
  simply does not resolve is left as written. A destination ending in `.md`
  can only have meant a note, so an unresolvable one warns.

- A reference written in a heading is resolved. `## See [[other]]` was
  collected nowhere, so it reached the output as the spelling it was written
  as, and if it named nothing at all, nothing said so.

- Diagnostics now have two severities. A **warning** carries the same code,
  span, and excerpt as an error, but never changes the exit code and never
  stops a build from writing. Where mdbase v0.3 defines a canonical code for
  the same condition it is rendered alongside tree-md's own, as
  `TM101 (schema_additional_properties): warning: …`.

- A file name may be anything the filesystem allows. `日本語のノート.tree.md`
  and `My Note.tree.md` build, and two folders may each hold a `note.tree.md`.
  A file name was previously required to be a Forester address, which rejected
  most of a real Obsidian vault — and rejected it in discovery, before any file
  was read, so stating `id:` in the front matter could not rescue it and the
  minting pass it needed could never be reached.

- `TM206`, for a tree that has no address and whose file name cannot be one.
  It is reported wherever nothing is going to mint one: `check`, and a build
  under `mint = "off"`. A build that mints reaches such a tree and gives it an
  address as usual.

- `[[folder/note]]` resolves path-style, and `.md` is stripped as well as
  `.tree`, so `[[notes.tree.md]]`, `[[notes.tree]]` and `[[notes]]` all reach
  the same tree. The exact spelling is still tried first.

- A reference target may now be spelled the way Obsidian writes a file name —
  with spaces, in any script. Addresses (`id:`, subtree names, `^anchor`) stay
  ASCII, because Forester reads an address off a file name it writes itself.
  What a target may not contain is what wiki syntax uses to delimit
  (`[ ] | # ^`) or a backslash, which is never unescaped here.

- Front matter `id`, which states a tree's identity instead of taking it from
  the file name. The output is named by the identity, so `id: 0073` in
  `a/about-me.tree.md` lands in `a/0073.tree`, and the note can be renamed
  without moving the address the site and every reference already use. A
  reference resolves against identities first and file names second, so
  existing forests keep working unchanged.

- `<!-- id: ID -->` as a synonym of `<!-- subtree: ID -->`, and a trailing
  `^ID` on a heading, which names the subtree that heading opens. The anchor
  form is what Obsidian writes for a block reference, so one note spells a
  subtree's address the same way in both tools.

- `tree-md build` gives an address to every tree that states none, writes it
  into the note's front matter, and reports what it gave to what. The scheme
  follows Forester's own convention — a base-36 number zero-padded to four
  digits — and is configurable under `[id]` (`alphabet`, `width`, `scheme`,
  `prefix`, `mint`). `scheme` defaults to `random`, which spreads addresses
  across the width; `sequential` gives a forest with a single writer dense,
  readable addresses instead, starting at zero to agree with the Obsidian
  plugin that mints into the same namespace. Either way the addresses avoid
  what a parse of the whole forest found taken. An `id` that is already
  written is never minted over, and a forest that does not compile is never
  rewritten. `mint = "off"` hands the job to something else — the Obsidian
  plugin, which mints from the same policy.

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

- Front matter is read in two steps that no longer know about each other. The
  parser builds the mapping exactly as written, in the JSON data model mdbase
  v0.3 §06 defines, carrying the source span of every key and value;
  interpretation is a separate pass over that tree. The reader previously
  assembled a fixed record directly from the YAML event stream, where the
  interleaving of `current_key`, `nesting` and the per-key flags could
  misread a shape: a promoted key given a list, `toc: [a, b]`, reported a
  phantom `unknown front matter key: "b"`. A shape cannot mislead a reader
  that interprets nothing.

- A link destination is carried as it was written, and percent-encoded only on
  the way out and only when it stays a URL. Encoding is now idempotent, so a
  URL a note wrote as `a%20b` no longer becomes `a%2520b`.

- A value read as text keeps the bytes it was written as, so `taxon: 1.50`
  emits `\taxon{1.50}` rather than a float rendered back as `1.5`. An explicit
  null now reads as absent rather than as an empty string.

- Front matter now ends at the **first** closing fence, the way Obsidian,
  Jekyll, Hugo and pandoc all end it, and the fence must be exactly three
  dashes with nothing after them but whitespace. The last such line was used
  before, so a `---` written in the body swallowed everything up to it into
  the YAML — usually surfacing as an unrelated `TM002`. `---` is now a
  thematic break like `***` and `___`.

- A repeated file name is no longer an error in itself. Two folders may each
  hold a `note.tree.md`; what may not be shared is an address, and that is
  still `TM201`. A reference that reaches more than one file is settled in the
  order mdbase v0.3 §08 fixes — the referring file's own folder, then the
  shortest path, then alphabetical — and warns when the folder rule did not
  settle it, because picking one of several is a decision the writer did not
  make.

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

### Fixed

- An asset path is looked up as it was written, so `![図](images/日本語.png)`
  finds `日本語.png`. The percent-encoded spelling was being used as the
  filesystem path, which made every non-ASCII asset — and every one with a
  space in its name — a `TM203` even though the file was there.

- A document with no H1 is titled by its **file name** again. Since `build`
  began minting addresses, the fallback was taking the identity instead, so a
  note written the Obsidian way — no H1, the file name serving as the title —
  was published as `\title{V0YI}`.

- The random minter is seeded. Every fresh process drew from the same default
  state, so two forests started independently were handed the same first
  address — the collision the random scheme exists to avoid. Within one forest
  the parsed set of taken addresses already prevented it.

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
