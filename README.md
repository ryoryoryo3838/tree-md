# tree-md

[![CI](https://github.com/ryoryoryo3838/tree-md/actions/workflows/ci.yml/badge.svg)](https://github.com/ryoryoryo3838/tree-md/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![OCaml](https://img.shields.io/badge/OCaml-%3E%3D5.3.0-ec6813.svg)](https://ocaml.org)

**Write your notes in Markdown. Publish them with [Forester](https://www.forester-notes.org/).**

`tree-md` compiles a strict Markdown dialect (`.tree.md`) into deterministic
Forester `.tree` source. Headings become nested subtrees, Obsidian-style wiki
links and embeds become tree references and transclusions, and every generated
file is manifest-owned, hash-checked, and byte-for-byte reproducible.

日本語版は [README.ja.md](./README.ja.md) を参照してください。

---

## Why

Forester is a lovely tool for hypertext mathematical writing, but its `.tree`
source is a bespoke markup language. If you already keep notes in Markdown — in
Obsidian, in your editor, in a git repo — you have to either abandon that or
maintain two copies.

`tree-md` lets Markdown stay the source of truth. You edit `.tree.md` files with
ordinary Markdown tooling; `tree-md build` produces the `.tree` files Forester
consumes.

It is deliberately **strict**. Markdown it cannot translate faithfully is
rejected with a diagnostic and a source excerpt, rather than silently dropped or
passed through. Every construct in the table below has a defined output; nothing
else compiles.

`tree-md` is independent from Forester: no Forester code is linked. It targets
the source language and CLI behavior of the `forester-6.0-dev` branch at commit
`30b73641cef02433ee158db6ddc77f7b49de60be`.

## At a glance

<table>
<tr><th><code>notes.tree.md</code></th><th><code>notes.tree</code></th></tr>
<tr valign="top"><td>

```markdown
---
date: 2026-08-02
taxon: Note
authors:
  - "[[miya]]"
  - "Ada Lovelace"
tags:
  - compiler
---

# Complete Example

A paragraph with **bold** and `code`.

<!-- subtree: my-sec -->
## Named Section

A [[wiki-link]] and math $x^2$.

![[standalone-embed]]
```

</td><td>

```tree
\title{Complete Example}
\date{2026-08-02}
\taxon{Note}
\author{miya}
\author/literal{Ada Lovelace}
\tag{compiler}

\p{A paragraph with \strong{bold} and \code{code}.}

\subtree[my-sec]{
\title{Named Section}
\p{A [[wiki-link]] and math #{x^2}.}
\transclude{standalone-embed}
}
```

</td></tr>
</table>

## Requirements

- OCaml >= 5.3.0
- Dune >= 3.22
- Forester 6.0-dev, to render the generated trees (not needed to run `tree-md`)

## Installation

### From source with opam

```bash
git clone https://github.com/ryoryoryo3838/tree-md.git
cd tree-md
opam install .
```

This installs the `tree-md` executable into your opam switch.

### From source with Dune package management

The repository pins its entire dependency closure, including the OCaml
compiler, in [`dune.lock/`](./dune.lock). No opam switch is needed:

```bash
git clone https://github.com/ryoryoryo3838/tree-md.git
cd tree-md
dune build           # fetches and builds the locked closure
dune exec -- tree-md --version
```

### With devbox

[`devbox.json`](./devbox.json) provides the exact toolchain used in development
and CI:

```bash
devbox shell
dune build
```

## Quick start

A `tree-md` workspace sits alongside a Forester forest. Create this layout:

```text
my-forest/
├── forest.toml          # Forester's own config
├── tree-md.toml         # tree-md's config
├── trees-md/            # Markdown sources you write
│   └── index.tree.md
├── trees/               # handwritten .tree files (optional)
└── generated/           # tree-md writes here — do not edit by hand
```

**1. Configure `tree-md.toml`:**

```toml
version = 1
forest  = "forest.toml"
sources = ["trees-md"]
output  = "generated"
target  = "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"
```

**2. Make sure `forest.toml` lists the output root under `[forest].trees`:**

```toml
[forest]
trees  = ["trees", "generated"]
assets = ["assets"]
```

**3. Write `trees-md/index.tree.md`:**

```markdown
---
taxon: Note
---

# Hello, forest

This is my first tree, with a [[reference]] to another one.
```

**4. Build:**

```console
$ tree-md build
build: 1 created, 0 replaced, 0 deleted, 0 unchanged

$ tree-md check          # read-only; confirms the generated state is clean
$ forester build forest.toml
```

`tree-md build` writes `generated/index.tree`. `forester build` turns the whole
forest into your site.

---

# Markdown to Forester correspondence

This is the complete language reference. Anything not listed here is rejected.

## Document shape

| Rule | Detail |
| --- | --- |
| File extension | Exactly `.tree.md` |
| Encoding | UTF-8, **no BOM** (a leading BOM is `TM003`) |
| Discovery | Recursive; symlinks are not followed; paths with a dot-leading component are ignored |
| Output path | Directory structure is mirrored, and the file is named by the identity — `trees-md/a/foo.tree.md` becomes `generated/a/foo.tree`, or `generated/a/mlnet-7.tree` if it states `id: mlnet-7` |
| Tree identity | The `id` in front matter, or the **filename stem** (`foo`) if it states none — never the path (`a/foo`). Duplicate identities anywhere in the forest are an error |

## Front matter

YAML front matter is optional. When present it must be the first thing in the
file, delimited by `---`.

| Markdown front matter | Forester output |
| --- | --- |
| `id: mlnet-7` | *(nothing)* — the tree's identity, see below |
| `date: 2026-08-02` | `\date{2026-08-02}` |
| `taxon: Note` | `\taxon{Note}` |
| `authors: ["[[miya]]"]` | `\author{miya}` — a tree reference |
| `authors: ["Ada Lovelace"]` | `\author/literal{Ada Lovelace}` — a literal name |
| `contributors: [...]` | `\contributor{...}` / `\contributor/literal{...}`, same rule |
| `tags: [compiler]` | `\tag{compiler}` |
| `meta: {institution: X}` | `\meta{institution}{X}` — one per entry, any name |

The distinction that matters: a value written as `"[[id]]"` becomes a **tree
reference** and must resolve; anything else becomes a **literal** string.

### Promoted keys

These names may be written as top-level keys instead of nesting them under
`meta`, so that an editor showing front matter as a property list can edit them
directly:

```text
position   institution   venue   source   doi     orcid
external   slides        video   bibtex   author  toc     lang
```

`institution: X` and `meta: { institution: X }` produce identical output. Giving
one name both ways is an error (`TM101`). `\meta` entries are emitted in source
order regardless of which spelling was used.

**The key set is closed.** An unrecognized key is `TM101`, so a misspelling is
reported rather than silently emitted.

### Minting an address

A tree that states no `id` is given one by `tree-md build`. The scheme follows
the convention Forester documents for its own forests — a base-36 number,
zero-padded to four digits — and is configurable:

```toml
[id]
alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"  # base 36
width    = 4          # minimum digits; a larger number simply takes more
scheme   = "sequential"   # or "random", for a forest with several contributors
prefix   = ""
mint     = "build"    # or "off", to have something else fulfil the requests
```

`build` mints for every tree that states no `id`, writes it into the note's
front matter, and reports what it gave to what:

```console
$ tree-md build
minted: trees-md/scratch.tree.md -> 0001
build: 1 created, 0 replaced, 0 deleted, 2 unchanged
```

An address is a published URL, so a build that invents one says so rather than
moving a tree in silence. **An address that is written is never minted over** —
state the `id` on anything whose address you have given out, and it is left
alone. Minting is what empties the plan, so a second build has nothing to do.

The addresses come from a real parse of the whole forest, not a guess, because
minting a collision would publish two trees at one URL and the address would
already be in the source by the time anything noticed.

`mint = "off"` leaves the requests standing for another tool to fulfil. Which
address to hand out stays here either way: a forest should have one scheme, not
one per tool. Only the writing moves.

The point of a number is that it says nothing, so nothing about the tree can
make you want to change it. Forester's documentation puts it directly: the
address exists "in such a way that you are not tempted to rename it, as you
might be when titles or dates are embedded into file names".

Human-readable addresses remain available and are worth using for the trees
Forester's own docs single out — bibliographic and biographical ones. Just
state the `id` and it is left alone; **an address that is written is never
minted over**.

The alphabet and prefix are checked when the config is read, so a policy that
could mint something illegal as an identity is rejected there rather than
part-way through a build.

### Front matter and thematic breaks

When a document has front matter, a `---` line is consumed as the YAML closing
delimiter, so `---` inside the body is *not* a thematic break. Use `***` or
`___` instead.

## Headings and subtrees

| Markdown | Forester output |
| --- | --- |
| `# Title` as the **first block** | root `\title{Title}` |
| `##` – `######` | nested `\subtree{ \title{...} ... }` |
| `<!-- subtree: ID -->` or `<!-- id: ID -->` before a heading | named `\subtree[ID]{ ... }` |
| `## Heading ^ID` — an anchor ending a heading | named `\subtree[ID]{ \title{Heading} ... }` |
| `<!-- h3 -->` | untitled `\subtree{ ... }` at level 3 |
| `<!-- h3:ID -->` | untitled, named `\subtree[ID]{ ... }` at level 3 |
| `<!-- /h3 -->` | closes every open subtree at level 3 or deeper |
| no H1 present | `\title` falls back to the filename stem |

Heading levels nest the way you would expect: an `##` opens a subtree, a
following `###` nests inside it, and a second `##` closes the first and opens a
sibling.

```markdown
# Root

## Section A

### Subsection of A

## Section B
```

```tree
\title{Root}
\subtree{
\title{Section A}
\subtree{\title{Subsection of A}}
}

\subtree{\title{Section B}}
```

A heading must have text. Markdown headings stop at six levels, so a run of
seven or more `#` is a paragraph, not a heading — both are errors rather than
silent changes of shape.

### Stable subtree identifiers

A `\subtree` with no ID has no addressable name. To link to a section, give it
a stable ID with a directive comment on the line before the heading:

```markdown
<!-- subtree: my-sec -->
## Named Section
```

```tree
\subtree[my-sec]{
\title{Named Section}
\p{...body...}
}
```

The grammar is `<!-- subtree: ID -->`. IDs match `[A-Za-z0-9][A-Za-z0-9._-]*`.
A directive must be immediately followed by a heading; an orphan, duplicate, or
malformed directive is an error.

### Untitled subtrees, and returning to a parent's body

Two shapes that Forester allows have no Markdown heading equivalent: a subtree
with no `\title`, and content that follows a subtree while still belonging to
its parent. Headings cannot express either, because a heading always carries a
title and always runs until the next heading of the same or a lower level.
Three directives cover the gap:

```markdown
# Root

Intro.

<!-- h2:aside -->

An untitled subtree, named so that it can still be linked.

<!-- h3 -->

Untitled and unnamed, nested one level deeper.

<!-- /h2 -->

Back in the root body, after the subtree ended.
```

```tree
\title{Root}
\p{Intro.}

\subtree[aside]{
\p{An untitled subtree, named so that it can still be linked.}

\subtree{
\p{Untitled and unnamed, nested one level deeper.}
}
}

\p{Back in the root body, after the subtree ended.}
```

Because the opening directive names its own level, a directive-delimited
subtree slots into the same level stack that headings build: `<!-- h3 -->`
closes any open level-3 or deeper subtree and opens a new one, exactly as
`###` does. Nothing can cross, and the two forms mix freely.

**The closing directive is optional.** Levels close on their own at the next
heading or directive of the same or a lower level, and at the end of the file.
Write `<!-- /hN -->` only when you want to write more of the parent's body
afterwards; it also closes a subtree that a heading opened.

| Rule | |
| --- | --- |
| Levels | `h2` through `h6`. `h1` is the document root |
| Identifier | optional on the opening form, rejected on the closing form |
| Placement | document level only, never inside a list or block quote |
| Emptiness | an untitled subtree with no content is an error |
| Closing | `<!-- /hN -->` with no open subtree at level *N* is an error |

Ordinary comments are still discarded. A comment whose first word *looks* like
one of these directives but does not parse — `<!-- H3 -->`, `<!-- h7 -->`,
`<!-- /h3:x -->` — is an error, because silently dropping it would change the
shape of the emitted tree with nothing to show for it.

## Inline elements

| Markdown | Forester output |
| --- | --- |
| `**strong**` | `\strong{strong}` |
| `*emphasis*` | `\em{emphasis}` |
| `` `code` `` | `\code{code}` |
| `[label](https://example.test)` | `[label](https://example.test)` — native syntax, passed through |
| `<https://example.test>` | native autolink |
| line ending in two spaces | `\<html:br>{}` |
| single newline inside a paragraph | a single space (soft break) |

## Block elements

| Markdown | Forester output |
| --- | --- |
| Paragraph | `\p{...}` |
| Block quote | `\blockquote{\p{...}}` |
| Unordered list | `\ul{\li{...}\li{...}}` |
| Ordered list starting at 1 | `\ol{\li{...}\li{...}}` |
| Ordered list starting at *n* ≠ 1 | `\<html:ol>[start]{n}{\li{...}}` |
| Fenced or indented code, no language | `\<html:pre>{\<html:code>{...}}` |
| Fenced code with a language | `\<html:pre>[class]{language-ocaml}{\<html:code>{...}}` |
| `***` / `___` thematic break | `\<html:hr>{}` |
| `<!-- comment -->` | discarded |

Tight and loose lists produce the same output; the distinction is not
represented in Forester.

## Links, embeds, and transclusion

| Markdown | Forester output | Meaning |
| --- | --- | --- |
| `[[id]]` | `[[id]]` | link to the tree `id` |
| `[[id\|alias]]` | `[alias](id)` | link with custom link text |
| `![[id]]` **alone in a paragraph** | `\transclude{id}` | embed the whole tree inline |

An `![[id]]` embed must stand alone in its own paragraph. An embed mixed with
other text, or inside a list or block quote, is an error (`TM106`) — Forester
transclusion is a block-level operation and there is no faithful inline
rendering of it.

### Resolution is closed-world

`[[target]]` resolves only against the known local identity index:

- roots of generated trees (from your `.tree.md` files),
- named subtrees (`<!-- subtree: ID -->` and `<!-- hN:ID -->`),
- roots of handwritten `.tree` files in the forest.

An unresolvable target is `TM202`. There is no such thing as a dangling link
that compiles.

### Identity, and the file it came from

A tree's identity is its `id` if it states one, and its file name otherwise. An
identity is emitted nowhere: it names the `.tree` that is written, which is
where Forester reads it from. So `id: mlnet-7` in `a/note.tree.md` produces
`a/mlnet-7.tree` and is addressed as `mlnet-7`.

Stating it is what lets the file be renamed — retitled, translated — without
moving the address the published site and every existing reference use.

The file name is then no longer the address, but it is still the search key: it
is what Obsidian autocompletes and writes. So a reference may name the file
instead, and it resolves to the identity:

```markdown
[[information-concept]]        →  [[mlnet-7]]
[[information-concept.tree]]   →  [[mlnet-7]]
[[mlnet-7]]                    →  [[mlnet-7]]
![[information-concept]]       →  \transclude{mlnet-7}
```

Identities are tried before file names, so a tree whose `id` happens to match
another tree's file name still wins.

### The `.tree` suffix rule

A target ending in `.tree` that is not itself in the index is retried without
that suffix. An Obsidian-style editor that addresses notes by filename sees
`notes.tree.md` as `notes.tree` and writes `![[notes.tree]]`; that resolves to
the tree `notes` and is emitted as `\transclude{notes}` — the identity, never
the spelling.

The exact spelling is tried first, so a tree whose identity genuinely is
`notes.tree` is not shadowed, and an unresolvable `[[missing.tree]]` is still a
`TM202`.

### The subtree anchor rule

Obsidian cannot address a subtree. It addresses a note, and reaches a subtree by
anchoring a block inside it:

| Markdown | Forester output |
| --- | --- |
| `![[notes#^aside]]` | `\transclude{aside}` |
| `[[notes#^aside\|the remark]]` | `[the remark](aside)` |
| `[[#^aside]]` | `[[aside]]` — the current note's own subtree |
| `A remark. ^aside` | `\p{A remark.}` — the anchor is dropped |

The note in that spelling only locates the anchor; the subtree's identity *is*
the anchor, so that is what the reference resolves to and what gets emitted —
the identity, never the spelling, exactly as with the `.tree` suffix. The
resolved id then goes through the closed-world check like any other target, so
`![[notes#^missing]]` is a `TM202`.

`#Heading` names a section rather than a subtree, and a section has no Forester
address unless the heading was given one, so it is a `TM105` that says as much.

A trailing `^id` is how Obsidian marks the block, not content, so it is stripped
rather than emitted. Only a token at the end of a block counts, and only one
that starts the run or follows a space — `the value x^2` keeps its caret. A
paragraph that held nothing but an anchor leaves no `\p{}` behind.

## Math

| Markdown | Forester output |
| --- | --- |
| `$x^2$` inline | `#{x^2}` |
| `$$y = mx + b$$` **alone in a paragraph** | `##{y = mx + b}` |

Like embeds, display math must stand alone in its own paragraph; display math
inside a list, block quote, or a paragraph with other text is `TM107`. The TeX
payload is scanned for brace balance before emission, so unserializable math is
reported rather than producing broken `.tree` source.

Fenced math blocks (` ```math `) are **not** supported.

## Images and assets

| Markdown | Forester output |
| --- | --- |
| `![External](https://example.test/img.png)` | `\<html:img>[src]{https://example.test/img.png}[alt]{External}{}` |
| `![Plot](images/x.png)` | `\<html:img>[src]{\route-asset{assets/images/x.png}}[alt]{Plot}{}` |

A **local** image path is routed through `\route-asset` against the asset roots
declared in `forest.toml`'s `[forest].assets`. The file must actually exist
under exactly one asset root: a missing asset is `TM203`, an ambiguous one that
matches several roots is `TM204`, and an unsafe path (absolute, escaping, or
with a hidden component) is `TM205`.

## Escaping

Characters that are syntactically significant to Forester are escaped
automatically when they appear in literal text:

| Character | Emitted as |
| --- | --- |
| `%` | `\%` |
| `\` `#` `{` `}` `[` `]` `(` `)` | `\verbFMD\|<char>FMD` |

This is why a literal `#` in prose appears as `\verbFMD|#FMD` in the output.
It is correct and renders as `#`.

## Rejected syntax

There is **no raw Forester pass-through escape hatch**. The following are
errors, not warnings:

| Rejected | Code |
| --- | --- |
| Raw inline or block HTML (other than comments) | `TM102` |
| GFM tables, task lists, strikethrough, footnotes | `TM102` |
| Fenced math blocks, any unrecognized Cmarkit extension | `TM102` |
| H1 anywhere except the first block; duplicate H1 | `TM103` |
| Skipped heading levels (`##` directly to `####`) | `TM103` |
| Headings nested inside a list item or block quote | `TM103` |
| A heading with no text | `TM103` |
| Seven or more `#`, which CommonMark reads as a paragraph | `TM103` |
| Invalid, duplicate, or orphan subtree directives | `TM104` |
| Subtree directives outside document level | `TM104` |
| A subtree level outside `h2`–`h6` | `TM104` |
| `<!-- /hN -->` with no open subtree at that level | `TM104` |
| An untitled subtree with no content | `TM104` |
| Malformed wiki link (`[[a\|b\|c]]`, invalid ID, empty alias) | `TM105` |
| Embeds inside lists, block quotes, or mixed into a paragraph | `TM106` |
| Display math inside lists, block quotes, or mixed into a paragraph | `TM107` |

---

## CLI reference

```text
tree-md check [--config PATH]
tree-md build [--config PATH]
```

| Command | Behavior |
| --- | --- |
| `check` | Validates the whole forest and reports generated-state problems **without writing any file**. Exits 0 only when the generated state is clean. |
| `build` | Validates first, then synchronizes generated outputs transactionally. |

`--config PATH` defaults to `./tree-md.toml`, read exactly from the current
working directory. **Parent directories are not searched.**

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success; for `check`, the generated state is also confirmed clean |
| `1` | Source, semantic, forest-consistency, or generated-state diagnostics |
| `2` | CLI usage, configuration, malformed manifest/journal, I/O, or internal failure |

### Environment

| Variable | Effect |
| --- | --- |
| `TREE_MD_BACKTRACE=1` | Print an OCaml backtrace on an internal error |

## Configuration

```toml
version = 1
forest  = "forest.toml"
sources = ["trees-md"]
output  = "generated"
target  = "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"
```

| Key | Meaning |
| --- | --- |
| `version` | Config schema version; must be `1` |
| `forest` | Path to Forester's `forest.toml` |
| `sources` | Source roots to scan for `.tree.md`. Must be distinct |
| `output` | Output root for generated `.tree`. Must not overlap a source root |
| `target` | Compatibility profile. Any other value is a configuration error |

All paths are relative to the directory containing `tree-md.toml`. The
referenced `forest.toml` supplies `[forest].trees` and `[forest].assets`,
relative to the directory containing `forest.toml`; the normalized output root
must appear in `[forest].trees`.

## Generated-file safety

The output directory is treated as owned by the compiler, and that ownership is
enforced rather than assumed.

- **Only manifest-owned files are managed.** `build` creates, replaces, and
  deletes only files named by the previous manifest
  (`<output>/.tree-md-manifest.json`). An unknown file is never deleted; an
  unknown file occupying an expected output path fails the build instead of
  being overwritten.
- **Manual modifications are protected.** Before replacing or deleting a managed
  file, `build` verifies its current SHA-256 against the manifest. A
  hand-edited generated file is an error and is never silently overwritten.
  There is intentionally **no `--force`**.
- **`check` never writes.** It creates no file and takes no lock. If a lock file
  exists it is opened read-only for a non-mutating test; an active writer is an
  exit-2 concurrency failure.
- **Interrupted builds roll forward.** All staged bytes are written and flushed
  before a pre-commit journal (`<output>/.tree-md-transaction.json`) is
  installed. After an interrupted commit, `check` reports the incomplete state
  (`TM305`) without writing, and the next `build` performs a hash-checked
  roll-forward under the writer lock.
- **Durability caveat.** The crash guarantee holds only on local filesystems
  that honor atomic same-filesystem `rename` and `fsync`. Network filesystems
  without those semantics are outside the supported durability model.

## Diagnostics

Every diagnostic has a stable code, a severity, a source span, and an excerpt.

| Range | Class | Exit |
| --- | --- | --- |
| `TM0xx` | Source encoding and front matter syntax | 1 |
| `TM1xx` | Document semantics (headings, directives, links, placement) | 1 |
| `TM2xx` | Forest consistency (identity, resolution, assets) | 1 |
| `TM3xx` | Generated state (missing, modified, stale, collision, interrupted) | 1 |
| `TM4xx` | Configuration, manifest, locking, I/O | 2 |
| `TM500` | Internal error | 2 |

<details>
<summary>Full code list</summary>

| Code | Meaning |
| --- | --- |
| `TM001` | Invalid UTF-8 |
| `TM002` | YAML front matter syntax error |
| `TM003` | File begins with a UTF-8 byte order mark |
| `TM101` | Front matter schema error (unknown key, duplicate, bad date) |
| `TM102` | Unsupported Markdown construct |
| `TM103` | Heading structure error |
| `TM104` | Subtree directive error |
| `TM105` | Malformed wiki link or embed |
| `TM106` | Embed in an invalid position |
| `TM107` | Display math in an invalid position, or unserializable TeX |
| `TM201` | Duplicate tree identity |
| `TM202` | Unresolved reference |
| `TM203` | Missing asset |
| `TM204` | Ambiguous asset (matches multiple asset roots) |
| `TM205` | Unsafe asset or source path |
| `TM301` | Missing generated output |
| `TM302` | Modified generated output (hash mismatch) |
| `TM303` | Stale generated output |
| `TM304` | Unknown file occupies an expected output path |
| `TM305` | Incomplete transaction from an interrupted build |
| `TM306` | Orphan staging directory |
| `TM401` | Configuration error |
| `TM402` | Malformed manifest |
| `TM403` | Transaction, locking, or filesystem-safety failure |
| `TM404` | I/O error |
| `TM500` | Internal error |

</details>

Example:

```console
$ tree-md build
TM003: error: file begins with a UTF-8 byte order mark; remove it
  --> trees-md/index.tree.md:1:1
   |
   | ﻿# BOM Title
   | ^
```

## Development

```bash
dune build              # build
dune runtest            # 18 Alcotest suites (444 cases) + cram scenarios
dune pkg lock           # refresh the pinned dependency closure
```

The external Forester compatibility job is
[`test/forester_compat.sh`](./test/forester_compat.sh); it is version-gated and
runs against a pinned Forester build rather than whatever is on `PATH`.

| Document | Contents |
| --- | --- |
| [`VERIFICATION.md`](./VERIFICATION.md) | Design requirement → test mapping |
| [`DEPENDENCIES.md`](./DEPENDENCIES.md) | Resolved dependency closure and license audit |
| [`CHANGELOG.md`](./CHANGELOG.md) | Release history |
| [`REFERENCE.md`](./REFERENCE.md) | Upstream reference links |

## Contributing

Issues and pull requests are welcome at
<https://github.com/ryoryoryo3838/tree-md>.

Because the compiler's whole value proposition is that its output is exact,
please add a test for any change to emission behavior. `test/fixtures/markdown/`
and `test/fixtures/forester/` hold the golden input/output pair.

## License

[MIT](./LICENSE) © ryoryoryo3838

No third-party source is vendored into this repository, and no linked
dependency carries a copyleft obligation. See [`DEPENDENCIES.md`](./DEPENDENCIES.md)
for the full audit.
