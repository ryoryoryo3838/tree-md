tree-md CLI: build and check subcommands with exact diagnostics and exit
codes 0/1/2. Each scenario copies a fixture workspace into the testcase
root first, so writes never touch the repository fixtures. The tree-md
binary is linked onto PATH by the cram stanza's %{bin:tree-md} dep; the
fixtures are available next to the cram directory.

  $ cp -rL ../fixtures/workspaces/clean clean
  $ cp -rL ../fixtures/workspaces/compile compile
  $ cp -rL ../fixtures/workspaces/compile-bad source-bad
  $ cp -rL ../fixtures/workspaces/unicode unicode
  $ cp -rL ../fixtures/workspaces/mdbase mdbase
  $ cp -rL ../fixtures/workspaces/publish publish

--version prints the package version and exits 0.

  $ tree-md --version
  0.1.0

--help documents the root command, its subcommands, and the exit codes.
The format is named rather than left to `auto`, which renders through
groff when a pager is around and through cmdliner's own formatter when
one is not — two different-looking man pages for the same binary.

  $ tree-md --help=plain
  NAME
         tree-md - Compile strict Markdown into Forester tree source.
  
  SYNOPSIS
         tree-md COMMAND …
  
  COMMANDS
         build [--config=PATH] [OPTION]…
             compile the forest and synchronize generated outputs
  
         check [--config=PATH] [OPTION]…
             check the workspace without writing any output
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         tree-md exits with:
  
         0   on success; check also confirms a clean generated state.
  
         1   on source, semantic, forest-consistency, or generated-state
             diagnostics.
  
         2   on usage, configuration, manifest, journal, I/O, or internal
             failure.
  

Usage errors (missing command, unknown command, unknown option) print
cmdliner's usage text to stderr and exit 2. TERM=dumb keeps the error
formatter's output plain across environments.

  $ TERM=dumb tree-md
  Usage: tree-md [--help] COMMAND …
  tree-md: required COMMAND name is missing, must be either 'build' or 'check'
  [2]

  $ TERM=dumb tree-md frobnicate
  Usage: tree-md [--help] COMMAND …
  tree-md: unknown command 'frobnicate'. Must be either 'build' or 'check'
  [2]

  $ TERM=dumb tree-md check --bogus
  Usage: tree-md check [--help] [--config=PATH] [OPTION]…
  tree-md: unknown option '--bogus'
  [2]

A pristine workspace reports each missing generated output as TM301 and
exits 1 without writing.

  $ tree-md check --config clean/tree-md.toml
  TM301: error: missing generated output
    --> $TESTCASE_ROOT/clean/generated/index.tree
  [1]

A successful build prints one summary line to stdout and exits 0.

  $ tree-md build --config clean/tree-md.toml
  build: 1 created, 0 replaced, 0 deleted, 0 unchanged

A check after a successful build is silent and exits 0.

  $ tree-md check --config clean/tree-md.toml

With the default ./tree-md.toml and no upward search, running from a
directory whose ancestor holds tree-md.toml is a TM401 configuration
failure and exits 2.

  $ cp -rL ../fixtures/workspaces/clean ancestor
  $ mkdir -p ancestor/a/b
  $ (cd ancestor/a/b && tree-md check)
  TM401: error: ./tree-md.toml: cannot read file: ./tree-md.toml: No such file or directory
    --> ./tree-md.toml
  [2]

Source diagnostics print path:line:column with an excerpt and caret and
exit 1.

  $ tree-md check --config source-bad/tree-md.toml
  TM202: error: unresolved wiki link "missing"
    --> $TESTCASE_ROOT/source-bad/trees-md/alpha.tree.md:3:1
     |
     | [[missing]]
     | ^^^^^^^^^^^
  TM204: error: ambiguous asset "images/shared.png" (matches multiple asset roots)
    --> $TESTCASE_ROOT/source-bad/trees-md/alpha.tree.md:5:1
     |
     | ![Shared](images/shared.png)
     | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  TM203: error: missing asset "images/absent.png"
    --> $TESTCASE_ROOT/source-bad/trees-md/alpha.tree.md:7:1
     |
     | ![Absent](images/absent.png)
     | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  TM102: error: raw block HTML is not supported
    --> $TESTCASE_ROOT/source-bad/trees-md/bad.tree.md:3:1
     |
     | <div>raw block html</div>
     | ^^^^^^^^^^^^^^^^^^^^^^^^^
  [1]

A build with source diagnostics prints the same diagnostics to stderr,
prints no summary line, and exits 1 without writing any output.

  $ tree-md build --config source-bad/tree-md.toml
  TM202: error: unresolved wiki link "missing"
    --> $TESTCASE_ROOT/source-bad/trees-md/alpha.tree.md:3:1
     |
     | [[missing]]
     | ^^^^^^^^^^^
  TM204: error: ambiguous asset "images/shared.png" (matches multiple asset roots)
    --> $TESTCASE_ROOT/source-bad/trees-md/alpha.tree.md:5:1
     |
     | ![Shared](images/shared.png)
     | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  TM203: error: missing asset "images/absent.png"
    --> $TESTCASE_ROOT/source-bad/trees-md/alpha.tree.md:7:1
     |
     | ![Absent](images/absent.png)
     | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  TM102: error: raw block HTML is not supported
    --> $TESTCASE_ROOT/source-bad/trees-md/bad.tree.md:3:1
     |
     | <div>raw block html</div>
     | ^^^^^^^^^^^^^^^^^^^^^^^^^
  [1]
  $ test ! -e source-bad/generated

A generated output modified after a build is reported by check as TM302
and exits 1.

  $ tree-md build --config compile/tree-md.toml >/dev/null
  $ printf 'tampered\n' > compile/generated/index.tree
  $ tree-md check --config compile/tree-md.toml
  TM302: error: modified generated output: hash does not match the manifest
    --> $TESTCASE_ROOT/compile/generated/index.tree
  [1]

An unsupported target in the configuration is a TM401 configuration
error and exits 2.

  $ printf 'version = 1\nforest = "forest.toml"\nsources = ["trees-md"]\noutput = "generated"\ntarget = "bogus-target"\n' > unsupported.toml
  $ tree-md check --config unsupported.toml
  TM401: error: unsupported.toml: unsupported target
    --> unsupported.toml
  [2]

A file name is a search key, not an address. Notes called 日本語のノート and
"My Note" build, get minted addresses, and are reachable by the names
Obsidian autocompletes. A note with no H1 is titled by its file, because the
address it was given is a number and a number is not a title.

  $ tree-md build --config unicode/tree-md.toml
  TM202: warning: "dup" names more than one file; resolved by mdbase link order (nearest folder, then shortest path). Give the tree an `id:` and reference that to say which one you mean
    --> $TESTCASE_ROOT/unicode/trees-md/refer.tree.md:7:1
     |
     | [[dup]] を参照。
     | ^^^^^^^
  minted: $TESTCASE_ROOT/unicode/trees-md/My Note.tree.md -> 0000
  minted: $TESTCASE_ROOT/unicode/trees-md/日本語のノート.tree.md -> 0001
  build: 6 created, 0 replaced, 0 deleted, 0 unchanged

  $ cat unicode/generated/index.tree
  \title{索引}
  \p{[[0001]] と [[0000]] へのリンク。}

  $ cat unicode/generated/0000.tree
  \title{My Note}
  \p{本文だけで見出しがないノート。}

A second build has nothing to do, and check agrees the state is clean. The
ambiguity warning stands — it is a warning, so it never fails either one.

  $ tree-md build --config unicode/tree-md.toml
  TM202: warning: "dup" names more than one file; resolved by mdbase link order (nearest folder, then shortest path). Give the tree an `id:` and reference that to say which one you mean
    --> $TESTCASE_ROOT/unicode/trees-md/refer.tree.md:7:1
     |
     | [[dup]] を参照。
     | ^^^^^^^
  build: 0 created, 0 replaced, 0 deleted, 6 unchanged
  $ tree-md check --config unicode/tree-md.toml
  TM202: warning: "dup" names more than one file; resolved by mdbase link order (nearest folder, then shortest path). Give the tree an `id:` and reference that to say which one you mean
    --> $TESTCASE_ROOT/unicode/trees-md/refer.tree.md:7:1
     |
     | [[dup]] を参照。
     | ^^^^^^^

A collection may declare what its front matter must look like, in the
`mdbase.yaml` and `_types/` its other mdbase tools already read. The schema
is checked against the front matter as written, and reported with mdbase's
own code beside tree-md's.

  $ printf -- '---\nid: wrong\nstatus: archived\n---\n\n# Wrong\n' > mdbase/trees-md/wrong.tree.md
  $ tree-md build --config mdbase/tree-md.toml
  TM101 (schema_enum): error: /status: must be one of "draft", "published" (type "note")
    --> $TESTCASE_ROOT/mdbase/trees-md/wrong.tree.md:3:9
     |
     | status: archived
     |         ^^^^^^^^
  [1]
  $ test ! -e mdbase/generated

`collection.read_defaults` supplies a value for a key the note leaves out. It
is an effective value: nothing is written back to the note.

  $ printf -- '---\nid: wrong\nstatus: draft\n---\n\n# Fixed\n' > mdbase/trees-md/wrong.tree.md
  $ tree-md build --config mdbase/tree-md.toml
  build: 2 created, 0 replaced, 0 deleted, 0 unchanged
  $ cat mdbase/generated/wrong.tree
  \title{Fixed}
  \taxon{Note}
  $ grep -c taxon mdbase/trees-md/wrong.tree.md
  0
  [1]

`[publish].from` names the trees a build starts from, and everything they
reach comes with them. A note nobody publishes is not compiled at all, so the
broken link in the diary does not fail the build for the pages that are.

  $ tree-md build --config publish/tree-md.toml
  build: 3 created, 0 replaced, 0 deleted, 0 unchanged, 1 unpublished
  $ find publish/generated -name '*.tree' | sort
  publish/generated/PUBLIC/index.tree
  publish/generated/PUBLIC/notes.tree
  publish/generated/private/frege.tree

Without the table every source is published, and the draft's broken link is a
`TM202` like any other.

  $ sed '/^\[publish\]/,$d' publish/tree-md.toml > publish/all.toml
  $ tree-md check --config publish/all.toml
  TM202: error: unresolved wiki link "存在しないノート"
    --> $TESTCASE_ROOT/publish/trees-md/DAILY/2026-08-19.tree.md:7:1
     |
     | [[存在しないノート]]
     | ^^^^^^^^^^^^
  [1]

A `from` that reaches nothing is said out loud. Patterns are matched below the
source root, with the root itself already spent, so one written against a
layout the sources are not in selects nothing — and publishing nothing emits
no tree and deletes every tree the build wrote before, which would otherwise
look exactly like a build with nothing to do.

  $ sed 's|^from = .*|from = ["MIYA-LIS.NET/**"]|' publish/tree-md.toml > publish/elsewhere.toml
  $ tree-md build --config publish/elsewhere.toml
  TM401: warning: $TESTCASE_ROOT/publish/elsewhere.toml: publish.from matched none of the 4 sources, so nothing is published
    --> $TESTCASE_ROOT/publish/elsewhere.toml
    note: its patterns are matched against the path of a source below its source root, with the root itself spent
  build: 0 created, 0 replaced, 3 deleted, 0 unchanged, 4 unpublished
  $ find publish/generated -name '*.tree' | sort
  $ tree-md build --config publish/tree-md.toml
  build: 3 created, 0 replaced, 0 deleted, 0 unchanged, 1 unpublished
