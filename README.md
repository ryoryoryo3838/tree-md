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

What it is *not* strict about is what you call your files. A file name is a
search key, not an address: notes called `日本語のノート` or `My Note` are
ordinary, and two folders may each hold a `note.tree.md`. The address a tree is
published at is the `id` it states, or the one `build` mints for it.

A few conditions are reported without failing the build. Those are **warnings**:
they carry the same code, span, and excerpt as an error, but they never change
the exit code and never stop a build from writing.

`tree-md` is independent from Forester: no Forester code is linked. It targets
the source language and CLI behavior of the `forester-6.0-dev` branch at commit
`30b73641cef02433ee158db6ddc77f7b49de60be`.

## At a glance

<table>
<tr><th><code>notes.tree.md</code></th><th><code>notes.tree</code></th></tr>
<tr valign="top"><td>

```markdown
---
id: notes
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
id: index
taxon: Note
---

# Hello, forest

This is my first tree.
```

`id` is the address the tree is published at, and naming it keeps this example
short. Leave it out and `build` mints one — see
[Minting an address](#minting-an-address). Every `[[link]]` you write has to
resolve to a tree that exists, so add the targets before you link to them.

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
| File name | Anything the filesystem allows. `日本語のノート.tree.md` and `My Note.tree.md` are ordinary, and the same stem may appear in two folders |
| Discovery | Recursive; symlinks are not followed; paths with a dot-leading component are ignored |
| Output path | Directory structure is mirrored, and the file is named by the identity — `trees-md/a/foo.tree.md` becomes `generated/a/foo.tree`, or `generated/a/mlnet-7.tree` if it states `id: mlnet-7` |
| Tree identity | The `id` in front matter; failing that the **filename stem** (`foo`), but only when that stem could be an address at all and no other tree answers to it — never the path (`a/foo`). Duplicate identities anywhere in the forest are an error |

By default `build` writes an `id` into any tree that lacks one before naming the
output, so the filename-stem fallback is what `check` sees, and what a build
sees under `mint = "off"`. See [Minting an address](#minting-an-address).

A tree with no address at all — because its file name could not be one, or
because another file is called the same — is `TM206` wherever nothing is going
to mint one, which is `check` and a build under `mint = "off"`.

## Front matter

YAML front matter is optional. When present it must be the first thing in the
file, delimited by `---`, and it must parse to a **mapping**.

**Any key may appear.** Front matter is an arbitrary mapping, as mdbase v0.3
§03 defines it; the table below is the part `tree-md` interprets, and every
other key is carried and emitted nowhere. An Obsidian vault is full of
`aliases`, `cssclasses`, `created` and `publish`, and none of them are this
compiler's business.

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

`tags`, `authors` and `contributors` accept a single bare scalar as well as a
list, because that is how Obsidian writes one of something: `tags: compiler` is
the same as `tags: [compiler]`.

A value read as text keeps the bytes it was written as, so `taxon: 1.50` emits
`\taxon{1.50}` rather than a float rendered back as `1.5`. An explicit null
reads as absent: `taxon:` with nothing after it emits no `\taxon`.

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

### Unrecognized keys

A key `tree-md` does not interpret is **carried, not rejected**. It appears in
no output and fails nothing.

The one exception is a key within an edit or two of one it does know. `taxo:`
is far more likely a typo than a property, and dropping it in silence would
lose a `\taxon{}` with nothing to show for it, so that case is reported:

```console
TM101 (schema_additional_properties): warning: unknown front matter key "taxo"; did you mean "taxon"?
  --> trees-md/note.tree.md:5:1
   |
   | taxo: Note
   | ^^^^
```

It is a **warning**, so the build still writes and still exits 0. A key in the
`x-` extension namespace mdbase reserves for private use is never treated as a
misspelling of anything.

### Minting an address

A tree that states no `id` is given one by `tree-md build`. The scheme follows
the convention Forester documents for its own forests — a base-36 number,
zero-padded to four digits — and is configurable:

```toml
[id]
alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"  # base 36
width    = 4        # minimum digits; a larger number simply takes more
scheme   = "random" # or "sequential", for a forest with a single writer
prefix   = ""
mint     = "build"  # or "off", to have something else fulfil the requests
```

`build` mints for every tree that states no `id`, writes it into the note's
front matter, and reports what it gave to what:

```console
$ tree-md build
minted: /home/you/my-forest/trees-md/scratch.tree.md -> V0YI
build: 1 created, 0 replaced, 0 deleted, 2 unchanged
```

One `minted:` line per note. The path is the absolute one discovery resolved,
so it names the file that was rewritten however the build was invoked.

An address is a published URL, so a build that invents one says so rather than
moving a tree in silence. **An address that is written is never minted over** —
state the `id` on anything whose address you have given out, and it is left
alone. Minting is what empties the plan, so a second build has nothing to do.

The addresses come from a real parse of the whole forest, not a guess, because
minting a collision would publish two trees at one URL and the address would
already be in the source by the time anything noticed. That parse is also the
gate: minting runs only once the forest has compiled, so a build that fails
rewrites nothing — not the outputs, and not your notes.

`check` never mints, because it never writes. A tree that states no `id` is
checked under its filename identity, so a note added since the last build is a
missing output (`TM301`) until `build` gives it an address. A note whose file
name could not be an address at all — `日本語のノート.tree.md`, `My Note.tree.md`
— has no identity to be checked under, so it is `TM206` until then.

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

Front matter ends at the **first** closing fence: the first unindented line
after the opening that is exactly `---`, with nothing after it but whitespace.
That is where Obsidian, Jekyll, Hugo and pandoc all end it. A later `---` is
ordinary body, so `---`, `***` and `___` are all thematic breaks.

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
| no H1 present | `\title` falls back to the **filename stem**, never to the identity — an address may be a minted number, and a number is not a title |

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
| `~~struck~~` | `\<html:del>{struck}` |
| `==highlighted==` | `\<html:mark>{highlighted}` — Obsidian's highlight |
| `%%comment%%` | *(nothing)* — Obsidian's comment, discarded like an HTML comment |
| `[^1]` | `\<html:sup>[class]{footnote-ref}{…}` — see [Footnotes](#footnotes) |
| `[label](https://example.test)` | `[label](https://example.test)` — native syntax, passed through |
| `[label](note.md)` | `[label](mlnet-7)` — a **local** destination names a tree, see below |
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
| `---` / `***` / `___` thematic break | `\<html:hr>{}` |
| GFM table | `\<html:table>` / `thead` / `tbody` / `tr` / `th` / `td`, alignment as `[style]{text-align: …}` |
| `- [ ]` / `- [x]` task item | `\li{\<html:input>[type]{checkbox}[disabled]{disabled}…{} …}` |
| `> [!note] Title` callout | `\<html:blockquote>[class]{callout}[data-callout]{note}{…}` |
| `[^1]: …` footnote definition | gathered into the footnote section — see [Footnotes](#footnotes) |
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

A tree's identity is its `id` if it states one. An identity is emitted nowhere:
it names the `.tree` that is written, which is where Forester reads it from. So
`id: mlnet-7` in `a/note.tree.md` produces `a/mlnet-7.tree` and is addressed as
`mlnet-7`.

Stating it is what lets the file be renamed — retitled, translated — without
moving the address the published site and every existing reference use.

The file name is then no longer the address, but it is still the search key: it
is what Obsidian autocompletes and writes. So a reference may name the file
instead, and it resolves to the identity:

```markdown
[[information-concept]]         →  [[mlnet-7]]
[[information-concept.tree]]    →  [[mlnet-7]]
[[information-concept.tree.md]] →  [[mlnet-7]]
[[notes/information-concept]]   →  [[mlnet-7]]
[[mlnet-7]]                     →  [[mlnet-7]]
![[information-concept]]        →  \transclude{mlnet-7}
```

Identities are tried before file names, so a tree whose `id` happens to match
another tree's file name still wins.

### Two vocabularies: addresses and targets

An **address** — a stated `id`, a subtree name, a `^anchor` — becomes a
Forester address, and Forester reads an address off a file name it writes
itself, so an address matches `[A-Za-z0-9][A-Za-z0-9._-]*`.

A **target** is only how a reference spells the thing it points at, and what
Obsidian writes there is a file name. So `[[日本語のノート]]`, `[[My Note]]`
and `[[people/alice]]` are all well-formed targets. What a target may not
contain is what wiki syntax itself uses — `[`, `]`, `|`, `#`, `^` — or a
backslash, which is never unescaped here. Whether a target names anything is
settled by resolution, and an unresolvable one is still `TM202`.

### Suffix and path rules

An editor shows `notes.tree.md` as `notes.tree` and writes `[[notes.tree]]`;
sometimes it writes the whole file name. Suffixes are stripped cumulatively, so
`[[notes.tree.md]]`, `[[notes.tree]]` and `[[notes]]` all reach the tree
`notes` and are all emitted as `[[notes]]` — the identity, never the spelling.

A target carrying a `/` is resolved path-style against the source tree, so
`[[people/alice]]` reaches `trees-md/people/alice.tree.md`.

The exact spelling is always tried before any stripped one, so a tree whose
identity genuinely is `notes.tree` is not shadowed, and an unresolvable
`[[missing.tree]]` is still a `TM202`.

### A Markdown link is a link too

In Forester, `[label](addr)` is a tree reference, not a URL: there is no
relative-link form. So a Markdown link whose destination is not an external
URI names a tree, and it resolves exactly as a wiki link does — mdbase v0.3
§08 counts one as a link too:

```markdown
[see](information-concept.md)   →  [see](mlnet-7)
[see](notes/information-concept) →  [see](mlnet-7)
[see](https://example.test)      →  unchanged, it is a URL
```

An unresolvable local destination is `TM202`. Passing it through untouched, as
earlier versions did, put a reference to an address no tree has into the
output and reported nothing.

### When a name reaches more than one file

Two folders may each hold a `note.tree.md`. A reference written `[[note]]` is
then settled in the order mdbase v0.3 §08 fixes: the referring file's own
folder first, then the shortest path, then alphabetical — so the answer never
depends on the order the filesystem happened to return.

Picking one of several is a decision you did not make, so it is said out loud:
if the folder rule did not settle it, resolution still succeeds and reports a
**warning** naming the target. Give one of the trees an `id:` and reference
that to say which you mean.

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

## Footnotes

Forester has no footnote of its own, so a footnote becomes what HTML makes one:
a superscript link into an ordered list at the end of the tree, with a link
back.

Footnotes are numbered by the order they are **first referred to**, not the
order they are defined, so moving a definition never renumbers anything. The
definitions are gathered into one section at the end of the tree however they
were scattered through the note, and a definition nothing refers to renders
nothing, so it is dropped.

The section belongs to the note rather than to whichever subtree happened to be
open when the document ran out, so every open subtree is closed before it.

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

The path is looked up as it was written, so an asset may be named anything the
filesystem allows: `![図](images/日本語.png)` finds `日本語.png`. A destination
containing a space needs CommonMark's angle-bracket form,
`![Plot](<images/my plot.png>)`, because a bare space ends a link destination.
Percent-encoding is applied to what is emitted for an *external* URL, never to
what is searched for on disk.

### Obsidian attachment embeds

`![[diagram.png]]` embeds an attachment rather than transcluding a tree —
settled by the extension, because an image has no address to transclude:

| Markdown | Forester output |
| --- | --- |
| `![[diagram.png]]` | `\<html:img>[src]{\route-asset{assets/…/diagram.png}}[alt]{diagram.png}{}` |
| `![[diagram.png\|300]]` | the same, plus `[width]{300}` |
| `![[diagram.png\|A diagram]]` | the same, with `[alt]{A diagram}` |

Obsidian writes just the file name, so a destination carrying no `/` is
searched for **by name** under the asset roots. Exactly one file must answer to
it: none is `TM203`, several is `TM204` and says to write the path instead.

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
| Malformed wiki link (`[[a\|b\|c]]`, a target containing `[ ] \| # ^ \\`, empty alias) | `TM105` |
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
| `[id]` | Optional table; the address policy `build` mints from. See [Minting an address](#minting-an-address) |

The five top-level keys are required and the key set is closed, `[id]`
included: an unknown key is `TM401` rather than a setting that quietly does
nothing.

All paths are relative to the directory containing `tree-md.toml`. The
referenced `forest.toml` supplies `[forest].trees` and `[forest].assets`,
relative to the directory containing `forest.toml`; the normalized output root
must appear in `[forest].trees`.

## mdbase

A forest is also an [mdbase](https://github.com/mdbase-dev/mdbase-spec)
collection, and `tree-md` reads what one declares. Nothing here is required:
a forest with no `mdbase.yaml` and no `_types/` behaves exactly as it did
before either existed.

`tree-md` targets **mdbase v0.3.0**, pinned the way the Forester target is
pinned. During major-zero the minor component is the compatibility boundary, so
a collection declaring `0.2.x` or `0.4.x` is refused with a message naming the
version this build supports.

### `mdbase.yaml`

```yaml
spec_version: "0.3.0"

settings:
  validation: error      # off | warn | error
  types_folder: _types
  id_field: id
  explicit_type_keys: [type, types]
```

| Setting | Effect here |
| --- | --- |
| `validation` | The severity a schema violation is reported at. `off` reports none; `warn` never fails a build |
| `types_folder` | Where type files are looked for |
| `id_field` | The key that holds a tree's address — read, and written by minting |
| `explicit_type_keys` | The front-matter keys that declare a record's type |

An unknown key is a **warning**, as §04 requires, and loading continues.
`record_extensions`, `include_subfolders` and `exclude` decide nothing here —
`tree-md` compiles the `.tree.md` files under the source roots named in
`tree-md.toml` — so setting one says so rather than quietly having no effect.

### Type files

A type file pairs a rule for selecting records with a JSON Schema for
validating them:

```markdown
---
kind: mdbase.type
name: note
version: 1

match:
  path_glob: "trees-md/**/*.tree.md"

schema:
  dialect: json-schema-2020-12
  value:
    type: object
    required: [status]
    additionalProperties: true
    properties:
      status: { type: string, enum: [draft, published] }

collection:
  read_defaults:
    taxon: Note
---

# Note

Every note under `trees-md/` states a status.
```

The schema validates the front matter **as written**, and a violation carries
mdbase's canonical code beside `tree-md`'s own:

```console
TM101 (schema_enum): error: /status: must be one of "draft", "published" (type "note")
  --> trees-md/wrong.tree.md:3:9
   |
   | status: archived
   |         ^^^^^^^^
```

`collection.read_defaults` then supplies a value for each key a record leaves
**missing** — an explicit null stays null — and nothing is written back to the
note. The example above publishes every note under `\taxon{Note}` without
repeating it in any of them.

### What is supported, and what is refused

The JSON Schema profile is exactly §06's required list: `type`, `required`,
`properties`, `additionalProperties`, `items`, `enum`, `const`, `oneOf`,
`anyOf`, `allOf`, `if`/`then`/`else`, `minimum`, `maximum`,
`exclusiveMinimum`, `exclusiveMaximum`, `multipleOf`, `minLength`,
`maxLength`, `pattern`, `minItems`, `maxItems`, `uniqueItems`, `$defs`, local
`$ref`, and assertion behaviour for `format: date`, `date-time` and `time`.
Lengths count characters. `pattern` uses §07's regular-expression subset:
Unicode-aware, without backreferences or look-around.

Anything outside that profile makes the schema fail to **compile**, rather
than being ignored when a record is validated. A schema that silently means
less than it says is worse than one that will not load: the collection would
report itself valid on the strength of a constraint nothing checked.

The same rule governs the type file's own sections. `match.path_glob`,
`match.fields_present`, `match.where`, `collection.read_defaults`,
`collection.display` and any `x-` extension are supported. These are refused,
each with a message saying what `tree-md` does instead:

| Section | Why |
| --- | --- |
| `collection.unique` | `tree-md` enforces address uniqueness across the whole forest itself, as `TM201` |
| `collection.links` | Every reference is resolved closed-world already, and an unresolved one is `TM202` |
| `collection.path` | An output is named after the tree's address |
| `collection.projections`, `match.expr` | Need the CEL profile, which `tree-md` does not implement (`unsupported_profile`) |
| `lifecycle` | Addresses are minted from the `[id]` policy in `tree-md.toml` |
| `runtime`, `migrations`, `implements` | `tree-md` runs no workflows, migrates nothing, and loads no data contracts |

### tree-md's own reading is separate

A declared schema says what the *collection* considers a valid record.
`tree-md` separately reads the keys it emits — `id`, `date`, `taxon`,
`authors`, `contributors`, `tags`, `meta` — and what it reports about those is
about what it can put into a `.tree`, not about validity. So an unusable
`date:` is still an error at `validation: off`: there is no `\date{}` to emit
for it either way.

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

Severity is `error` or `warning`. **Only errors decide the exit code**, and only
an error stops a build from writing; a warning is reported and stepped over. The
class table below is what an *error* of that range exits with.

Where mdbase v0.3 defines a canonical code for the same condition, it is
rendered alongside — `TM101 (schema_additional_properties): warning: …`.

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
| `TM206` | Tree has no address, and its file name cannot be one |
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
dune runtest            # 20 Alcotest suites (500 cases) + cram scenarios
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

No third-party source is vendored into this repository. Two linked packages
carry an LGPL expression — `menhirLib` and `re` — and both carry the explicit
`OCaml-LGPL-linking-exception`, the same exception the OCaml runtime itself
carries, so neither imposes a copyleft obligation. See
[`DEPENDENCIES.md`](./DEPENDENCIES.md) for the full audit.
