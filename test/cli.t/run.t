tree-md CLI: build and check subcommands with exact diagnostics and exit
codes 0/1/2. Each scenario copies a fixture workspace into the testcase
root first, so writes never touch the repository fixtures. The tree-md
binary is linked onto PATH by the cram stanza's %{bin:tree-md} dep; the
fixtures are available next to the cram directory.

  $ cp -rL ../fixtures/workspaces/clean clean
  $ cp -rL ../fixtures/workspaces/compile compile
  $ cp -rL ../fixtures/workspaces/compile-bad source-bad

--version prints the package version and exits 0.

  $ tree-md --version
  0.1.0

--help documents the root command, its subcommands, and the exit codes.

  $ tree-md --help
  TREE-MD(1)                      Tree-md Manual                      TREE-MD(1)
  
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
             Show  this  help  in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the  format  is  pager  or  plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         tree-md exits with:
  
         0   on success; check also confirms a clean generated state.
  
         1   on   source,   semantic,   forest-consistency,  or  generated-state
             diagnostics.
  
         2   on  usage,  configuration,  manifest,  journal,  I/O,  or  internal
             failure.
  
  Tree-md 0.1.0                                                       TREE-MD(1)

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
