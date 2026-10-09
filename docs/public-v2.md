# Public-v2 JSON bridge (local, not publication authorization)

The new canonical command is **`tree_of_md`** (underscore). The package and
repository remain `tree-md`; `Tree_md`, the old `tree-md` executable, and its
configuration are retained for legacy consumers. No package/version rename is
required. This path never reads a vault or runs the legacy discovery, publication
selection, or attachment-copy pipeline.

```sh
devbox run -- dune build @install
devbox run -- dune exec tree_of_md -- \
  --public-forest approved-public-v2.json --out-dir fresh-trees
```

The installed library façade is `tree-md.tree_of_md`:

```ocaml
module Public = Tree_of_md.Public_forest

let result =
  Public.convert_file ~input:"approved-public-v2.json" ~out_dir:"fresh-trees"
```

`Public.of_string` loads and validates the wire schema. `Public.compile_forest`
returns sorted `(filename, source)` pairs without filesystem access.
`Public.load_file`, `Public.write_forest`, and `Public.convert_file` provide the
file boundary. Errors contain only stable `PF_*` codes. CLI success prints
`PF_OK <root-count>`; conversion errors exit 1, argument errors exit 2, and neither
prints input text, exception payloads, or supplied paths.

## Exact wire format

```ts
type Attribution = {kind:'literal'; value:string} | {kind:'tree'; id:string};
type Tree = {
  id?: string; // required at the top level; absent only for anonymous sections
  title: string;
  taxon?: string;
  authors: Attribution[];
  dates: string[];
  contributors: Attribution[];
  properties: Record<string,string[]>;
  citationAuthors: string[];
  publicationYear?: string;
  content: Node[];
};
type Node = {kind:'markdown'; text:string}
  | {kind:'subtree'; tree:Tree}
  | {kind:'transclude'; id:string; header:boolean; toc:boolean};
type Forest = {schema:'forester-public-v2'; trees:Tree[]; assets:[]};
```

All required arrays/maps must be present, including empty ones. Unknown keys,
duplicate JSON keys, wrong types, unsupported discriminants, and nonempty assets
are errors. JSON comments, trailing commas, invalid UTF-8, invalid Unicode
surrogates, and control characters are rejected rather than accepted as parser
extensions. IDs match exactly `[A-Za-z0-9-]+`; spelling is preserved and ASCII
case-fold collisions are rejected. Reference spelling must match an existing
public definition exactly, not a case-normalized or filename-derived target.

Each top-level ID produces `<ID>.tree`. Named descendants are emitted once as
native `\subtree[ID]` definitions, never also as files. Anonymous children are
native `\subtree` sections with no user-defined route. Root files are sorted by
ID; content placement order is preserved. Structured transclusions are native
ID references, not body expansion; `header`/`toc` are scoped to that placement.
Containment and transclusion cycles are rejected, including cycles through
anonymous sections. Ordinary backlink cycles are allowed.

## Metadata and Markdown boundaries

Titles, taxons, literal attributions, and property values use the library's
literal escaping. Tree attributions use only verified public IDs. V2 dates must
be exactly `YYYY-MM-DD`, with a nonzero four-digit year and a real calendar day
checked by the existing validator (including leap years). Timestamps, partial
dates, whitespace, and linked dates fail with `PF_DATE`; the pinned native
renderer otherwise loses the clock/timezone. The legacy `Metadata.valid_date`
API and legacy Markdown conversion retain their timestamp support unchanged.
Nested definitions emit only their supplied local values; native Forester
inherits public-parent authors/dates once. Contributors/properties are not
reattached from ancestors. `citationAuthors` are literal native `author` metadata;
`publicationYear` is literal `publication-year` metadata, not a note date or a
bibliographic-formatting guarantee.

Only these properties are supported: `position`, `institution`, `venue`,
`source`, `doi`, `orcid`, `external`, `slides`, `video`, `bibtex`, `author`.
`external`, `slides`, and `video` require safe absolute HTTP(S) URLs. The converter
does not fetch any URL.

`doi` and `orcid` accept a bare native identifier or an exact lowercase
`http://` / `https://` resolver URL. DOI hosts are `doi.org`, `www.doi.org`, and
`dx.doi.org`; ORCID uses only `orcid.org`. The URL path must itself be a supported
identifier. Only native metadata emission removes that one resolver prefix;
the input JSON, Markdown, IDs, and identifier spelling are never rewritten.
Forester supplies its own HTTPS prefix, producing, for example,
`https://www.doi.org/10.0000/synthetic` and
`https://orcid.org/0000-0000-0000-0000`, not double-prefixed URLs.

Supported DOI syntax is `10.` followed by 4–9 ASCII digits, `/`, and a nonempty
suffix containing only ASCII letters/digits or `- . _ ; ( ) / : +`. ORCID syntax
is four hyphen-separated groups of four ASCII digits, with an uppercase `X`
also permitted as the final character. This is a deliberately restricted syntax
contract, not registry existence, DOI resolution, or ORCID checksum validation;
the examples above are synthetic. Unsupported/malformed identifiers, unknown
hosts, credentials, ports, query strings, fragments, percent encoding, alternate
scheme/host casing, and extra resolver prefixes fail with `PF_SCHEMA`. No
trimming, decoding, guessed repair, or source-token normalization is performed.
Other property values continue to use the same literal escaping.

Every Markdown chunk is parsed in isolation through the existing Markdown/IR
library, with an independent pre-lowering guard and a post-lowering allowlist.
Code examples remain inert. Ordinary math is emitted as adaptive native
verbatim inside the math wrapper, so TeX cannot execute Forester commands.
Public wikilinks must use `[[ID|literal-safe-label]]`; encoded labels decode one
entity layer only and are escaped again as literal Forester link labels.
Markdown links may use an exact public ID or an allowed external URL.

Semantic headings, subtree directives/anchors, file frontmatter, hidden
comments, raw HTML/Forester, residual or filename-based wikilinks, unstructured
embeds, images/attachments, and link-card payloads are refused. Code/math examples
are not treated as definitions or graph edges. Cross-chunk Markdown reference definitions, fences,
footnotes, or declarations are not joined. Inline transclusion is unsupported;
use a structured block-position node. No publication shorthand is implemented:
publication authorization belongs to the producer, not this converter.

## Filesystem and resource limits

Validation, Markdown checks, target resolution, and cycle checks finish before
any output directory is created. Input must be a regular nonsymlink file.
Symlink input/output components, `..` components, existing files, and nonempty
output directories are refused. Writes use exclusive creation and never
replace existing files. OS I/O failure can leave partial staging; on any failed
conversion the caller must discard the entire staging directory, not publish
or reuse it. This is not an atomic snapshot transaction. Existing empty output
directories and new parent directories are supported. Revocation requires a
replacement snapshot and a new/empty output directory; stale outputs cannot be
silently reused.

Limits: 8 MiB JSON, JSON nesting 128, tree nesting 32, 256 KiB per string/chunk,
250-byte IDs (flat filename limit), 200,000 JSON value tokens, 20,000 structured
tree/content nodes, and 20,000 Markdown AST nodes per chunk. Standalone CR in a
Markdown chunk is unsupported; LF and CRLF are accepted.

The namespace checks and exclusive final-file writes are not a promise of
resistance to a hostile process concurrently replacing directory ancestors.
Use an isolated, locally controlled staging directory. Snapshot approval,
expected SHA-256, immutable content revision, staging-manifest verification,
and publication authorization remain the caller's responsibility; the loader
cannot infer them from the JSON. Raw private content accidentally supplied as
an otherwise valid literal is not a publication policy this consumer can infer.

## Verification target

The compatibility target is Forester `6.0~dev` at full revision
`f8fb5f5d88923db36643cf9c20c662adff969c98`. Exercise generated trees with its
production HTML backend (no `--dev`). Legacy XML is a separate verification
build; `--emit-legacy-xml` selects XML instead of article HTML on this revision.
The native HTML renderer omits backmatter on the configured home tree; verify
References/Backlinks on an independently addressed non-home child as well.

The new `public_forest_test` suite covers the JSON boundary, ownership/order,
metadata, placement flags, graph checks, hostile Markdown, bounds, façade,
actual CLI, symlink/stale-output refusal, and rejection without writes. Run it
with its executable dependency built, or via `dune runtest`:

```sh
devbox run -- dune build bin/public_main.exe test/public_forest_test.exe
devbox run -- dune exec test/public_forest_test.exe
devbox run -- dune runtest --force
```

The real native DOI/ORCID regression is opt-in when that binary is available:

```sh
PUBLIC_FOREST_TEST_FORESTER=/path/to/pinned/forester \
PUBLIC_FOREST_TEST_FIXTURE=/path/to/actual-producer-public-v2.json \
  dune exec test/public_forest_test.exe -- test public-v2 16
```

Without `PUBLIC_FOREST_TEST_FIXTURE` it uses equivalent synthetic values. It
builds production native HTML in scratch and checks the rendered hrefs, not
just emitted `.tree` substrings. The ordinary suite also tests restricted
identifiers/hostile URLs, full calendar dates, and unchanged legacy timestamps.

Synthetic Forester builds/browser checks are converter acceptance evidence,
not evidence that the producer's private/public selection was exercised or that
real content is approved for upload or deployment.
