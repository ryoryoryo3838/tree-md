# tree-md Dependency Audit

This file records the complete resolved dependency closure of the `tree-md`
package and the license audit that justifies the project's own
[MIT `LICENSE`](./LICENSE).

The authoritative, reproducible closure is [`dune.lock/`](./dune.lock), used by
`dune build` through the `(pkg enabled)` setting in
[`dune-workspace`](./dune-workspace). It is regenerated with:

```bash
dune pkg lock          # resolve and pin the closure
ls dune.lock/*.pkg     # the resolved package set
```

The audit classifies every package as **runtime** (linked into the shipped
`tree-md` binary), **test** (linked only into the test executables), **build**
(run at build time, never linked into compiler outputs), or **compiler/stdlib**
(the OCaml toolchain itself). Classification was verified against the actual
dune link closure (`lib/dune` libraries and `ocamlobjinfo` on the built
artifacts), not assumed from package metadata.

## License conclusion

> **No linked dependency is AGPL, GPL, or plain LGPL, so the project is free to
> license itself permissively; it is released under the MIT License.** Every
> dependency whose license expression contains `LGPL` is either (a) linked only
> under the explicit `OCaml-LGPL-linking-exception` (the standard OCaml
> ecosystem exception that permits any program to link the library without
> copyleft obligations), or (b) a build tool that is never linked or shipped.
> Two packages carrying an LGPL expression are linked — `menhirLib` and `re` —
> and both carry the explicit `OCaml-LGPL-linking-exception`, which is the same
> exception the OCaml compiler's own runtime carries and imposes no copyleft
> obligation on a program that links them.
> The only GPL-licensed package in the closure, `menhir`, is strictly a
> build-time parser generator for `otoml`; its license does not propagate to
> the parser it generates or to any compiled artifact. No third-party source is
> vendored into this repository, so MIT applies cleanly to the whole of
> `lib/`, `bin/`, and `test/`.

| License class | Packages |
| --- | --- |
| ISC | cmarkit, cmdliner, yaml, uutf, alcotest, astring, fmt, logs, bos, fpath, rresult, topkg, ocaml-config |
| MIT | otoml, ctypes, integers, digestif, eqaf, dune-configurator, csexp, ocamlfind, ocaml-syntax-shims |
| BSD-3-Clause | yojson |
| LGPL with OCaml-LGPL-linking-exception | menhirLib, menhirCST, menhirSdk, ocaml, ocaml-base-compiler, ocaml-compiler, ocamlbuild, re, stdlib-shims |
| GPL (build tool only, never linked) | menhir (GPL-2.0-only) |

Licenses above were confirmed against the `license:` field of each package's
definition in the opam repository, not inferred.

## Direct dependencies (from `dune-project`)

These are the only packages the compiler declares. Seven are permissively
licensed; `re` carries an LGPL expression with the OCaml linking exception,
which is the same footing the compiler's own runtime stands on.

| Package | Resolved version | License | Purpose |
| --- | --- | --- | --- |
| cmarkit | 0.4.0 | ISC | CommonMark parsing, locations, custom resolver, math |
| yaml | 3.2.0 | ISC | Located YAML event stream for front matter |
| otoml | 1.0.5 | MIT | TOML configuration parsing |
| cmdliner | 2.1.1 | ISC | Command-line interface |
| yojson | 3.0.0 | BSD-3-Clause | Generated-file manifest JSON |
| digestif | 1.3.1 | MIT | SHA-256 manifest hashes |
| re | 1.14.0 | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | `pattern` in the JSON Schema profile, and `matches` in mdbase's structured match predicates |
| alcotest | 1.9.1 | ISC | Unit and integration test framework (test only) |

## Runtime-linked closure

Packages linked into the shipped `tree-md` binary. Verified via the `tree_md`
library stanza (`cmarkit yaml unix otoml digestif yojson cmdliner`) and
`ocamlobjinfo` on `_build/default/bin/main.exe`.

| Package | Resolved version | License | Source | Why it is linked |
| --- | --- | --- | --- | --- |
| cmarkit | 0.4.0 | ISC | https://erratique.ch/software/cmarkit/releases/cmarkit-0.4.0.tbz | CommonMark parser |
| cmdliner | 2.1.1 | ISC | https://erratique.ch/software/cmdliner/releases/cmdliner-2.1.1.tbz | CLI parser |
| yaml | 3.2.0 | ISC | https://github.com/avsm/ocaml-yaml/releases/download/v3.2.0/yaml-3.2.0.tbz | YAML front matter |
| ctypes | 0.24.0 | MIT | https://github.com/yallop/ocaml-ctypes/archive/refs/tags/0.24.0.tar.gz | yaml's C bindings |
| integers | 0.8.0 | MIT | https://github.com/yallop/ocaml-integers/archive/0.8.0.tar.gz | ctypes integer support |
| otoml | 1.0.5 | MIT | https://github.com/dmbaturin/otoml/archive/refs/tags/1.0.5.tar.gz | TOML configuration |
| menhirLib | 20250912 | LGPL-2.0-only WITH OCaml-LGPL-linking-exception | https://gitlab.inria.fr/fpottier/menhir/-/archive/20250912/archive.tar.gz | runtime library for otoml's generated TOML parser |
| uutf | 1.0.4 | ISC | https://erratique.ch/software/uutf/releases/uutf-1.0.4.tbz | UTF-8 codec (otoml) |
| yojson | 3.0.0 | BSD-3-Clause | https://github.com/ocaml-community/yojson/releases/download/3.0.0/yojson-3.0.0.tbz | manifest JSON |
| digestif | 1.3.1 | MIT | https://github.com/mirage/digestif/releases/download/v1.3.1/digestif-1.3.1.tbz | SHA-256 |
| eqaf | 0.10 | MIT | https://github.com/mirage/eqaf/releases/download/v0.10/eqaf-0.10.tbz | constant-time compare for digestif |
| re | 1.14.0 | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | https://github.com/ocaml/ocaml-re/archive/refs/tags/1.14.0.tar.gz | regular expressions for JSON Schema `pattern` and mdbase `matches` |

Two LGPL-expression packages are linked into the binary, `menhirLib` and `re`.
Both carry the explicit `OCaml-LGPL-linking-exception`, identical in effect to
the OCaml compiler's own license, so linking them imposes no copyleft
obligation.

`re` was test-only before mdbase v0.3 conformance: its JSON Schema profile
requires `pattern`, and its structured match predicates require `matches`, and
neither can be met without a regular-expression engine. It is already in the
locked closure through `alcotest`, so promoting it added no new package.

## OCaml compiler and standard library

The toolchain is linked as the runtime of any OCaml program and carries the
standard `OCaml-LGPL-linking-exception`.

| Package | Resolved version | License | Notes |
| --- | --- | --- | --- |
| ocaml | 5.3.0 | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | compiler + stdlib (virtual) |
| ocaml-base-compiler | 5.3.0 | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | compiler implementation |
| ocaml-compiler | 5.3.0 | LGPL-2.1-or-later WITH OCaml-LGPL-linking-exception | https://github.com/ocaml/ocaml/releases/download/5.3.0/ocaml-5.3.0.tar.gz |
| ocaml-config | 3 | ISC | switch configuration |
| base-threads / base-unix | base | — | virtual stdlib packages (the two the lock resolves) |

## Test-only closure

Linked only into the Alcotest/cram test executables; never shipped.

| Package | Resolved version | License | Source | Required by |
| --- | --- | --- | --- | --- |
| alcotest | 1.9.1 | ISC | https://github.com/mirage/alcotest/releases/download/1.9.1/alcotest-1.9.1.tbz | tree-md (test) |
| astring | 0.8.5 | ISC | https://erratique.ch/software/astring/releases/astring-0.8.5.tbz | alcotest, bos |
| fmt | 0.11.0 | ISC | https://erratique.ch/software/fmt/releases/fmt-0.11.0.tbz | alcotest, bos |
| logs | 0.10.0 | ISC | https://erratique.ch/software/logs/releases/logs-0.10.0.tbz | alcotest, bos |
| stdlib-shims | 0.3.0 | LGPL-2.1-only WITH OCaml-LGPL-linking-exception | https://github.com/ocaml/stdlib-shims/releases/download/0.3.0/stdlib-shims-0.3.0.tbz | alcotest |
| ocaml-syntax-shims | 1.0.0 | MIT | https://github.com/ocaml-ppx/ocaml-syntax-shims/releases/download/1.0.0/ocaml-syntax-shims-1.0.0.tbz | alcotest |
| bos | 0.3.0 | ISC | https://erratique.ch/software/bos/releases/bos-0.3.0.tbz | yaml (test) |
| fpath | 0.7.3 | ISC | https://erratique.ch/software/fpath/releases/fpath-0.7.3.tbz | bos |
| rresult | 0.7.0 | ISC | https://erratique.ch/software/rresult/releases/rresult-0.7.0.tbz | bos |

Every LGPL-expression package listed here carries the OCaml linking exception.
`stdlib-shims` is test-only and never reaches the shipped binary; `re` is no
longer in this section, having become a runtime dependency, and is listed with
the runtime closure above.

## Build tools (licenses do not propagate)

These tools run at build time and generate or orchestrate compilation. They are
never linked into or shipped with compiler outputs. Per the design spec:
"Build tools that generate source do not become linked runtime components, but
their licenses are still recorded in the audit."

| Package | Resolved version | License | Source | Role |
| --- | --- | --- | --- | --- |
| dune | >= 3.22 | MIT | https://github.com/ocaml/dune | build orchestrator; the driver itself, so it is not a package in `dune.lock/` — the required range is `dune-project`'s |
| dune-configurator | 3.23.1 | MIT | https://github.com/ocaml/dune/releases/download/3.23.1/dune-3.23.1.tbz | yaml system-config discovery |
| csexp | 1.5.2 | MIT | https://github.com/ocaml-dune/csexp/releases/download/1.5.2/csexp-1.5.2.tbz | dune-configurator |
| ocamlfind | 1.9.8+dune | MIT | https://github.com/ocaml/ocamlfind/archive/refs/tags/findlib-1.9.8.tar.gz | package manager (cmarkit) |
| ocamlbuild | 0.16.1+dune | LGPL-2.0-or-later WITH OCaml-LGPL-linking-exception | https://github.com/gridbugs/ocamlbuild/archive/refs/tags/0.16.1+dune.tar.gz | legacy build system (cmarkit) |
| topkg | 1.1.1 | ISC | https://erratique.ch/software/topkg/releases/topkg-1.1.1.tbz | release packager (cmarkit) |
| menhir | 20250912 | **GPL-2.0-only** | https://gitlab.inria.fr/fpottier/menhir/-/archive/20250912/archive.tar.gz | parser generator for otoml |
| menhirCST | 20250912 | LGPL-2.0-only WITH OCaml-LGPL-linking-exception | https://gitlab.inria.fr/fpottier/menhir/-/archive/20250912/archive.tar.gz | menhir component |
| menhirSdk | 20250912 | LGPL-2.0-only WITH OCaml-LGPL-linking-exception | https://gitlab.inria.fr/fpottier/menhir/-/archive/20250912/archive.tar.gz | menhir component |
| conf-pkg-config | 4 | **GPL-1.0-or-later** | — (conf package) | build-time system check (pkg-config presence). Not in `dune.lock/`, which resolves `yaml` to `dune-configurator` alone; it appears only when the closure is resolved through opam |

`menhir` is the only GPL-2.0 package. It is a parser generator invoked while
building `otoml`: it consumes otoml's grammar and produces OCaml source that is
part of otoml's own MIT-licensed work. The generator's license does not
propagate to the generated parser, and menhir itself is not linked into any
compiler output. `conf-pkg-config` only verifies that the system `pkg-config`
tool exists; it compiles nothing and links nothing.

## Installed but not linked into compiler outputs

None of the packages below is in `dune.lock/`. They come from the
`opam list --installed --required-by tree-md --recursive` query run in the
shared development switch, where they are installed as dependencies of other
projects in that switch or of uutf's own development suite. They are recorded
because that query was the audit's original source and because none of them
carries a non-exception copyleft license either way.

| Package | Resolved version | License | Source |
| --- | --- | --- | --- |
| cstruct | 6.2.0 | ISC | https://github.com/mirage/ocaml-cstruct/releases/download/v6.2.0/cstruct-6.2.0.tbz |
| num | 1.6 | LGPL-2.1-only WITH OCaml-LGPL-linking-exception | https://github.com/ocaml/num/archive/refs/tags/v1.6.tar.gz |
| parsexp | v0.17.0 | MIT | https://github.com/janestreet/parsexp/archive/refs/tags/v0.17.0.tar.gz |
| sexplib | v0.17.0 | MIT | https://github.com/janestreet/sexplib/archive/refs/tags/v0.17.0.tar.gz |
| sexplib0 | v0.17.0 | MIT | https://github.com/janestreet/sexplib0/archive/refs/tags/v0.17.0.tar.gz |
| uchar | 0.0.2 | LGPL-2.1-only WITH OCaml-LGPL-linking-exception | https://github.com/ocaml/uchar/releases/download/v0.0.2/uchar-0.0.2.tbz |

`uchar` is a development dependency of `uutf`; the installed `uutf` library
declares an empty runtime `requires` and tree-md does not link it. `sexplib`,
`parsexp`, `num`, and `cstruct` belong to other installed projects in the
shared switch. All carry permissive licenses or the OCaml linking exception.

## Lockfile

[`dune.lock/`](./dune.lock) is the single lock artifact. It is the closure used
by `dune build` via `(pkg enabled)`, is regenerated with `dune pkg lock`, and is
pinned to OCaml 5.3.0 by the `(constraints ...)` stanza in
[`dune-workspace`](./dune-workspace). It pins every dependency, including the
compiler, so it can recreate this build environment on another host without an
opam switch.

Note that [`tree-md.opam`](./tree-md.opam) declares **lower bounds** (`>=`),
which express the supported version range for publication, while `dune.lock/`
carries the exact pins. The two therefore differ by design: a `>=` constraint in
the opam file is not a loosened pin.

A second lockfile, `tree-md.opam.locked`, previously recorded a snapshot of an
`opam`-managed development switch. It was removed because it duplicated
`dune.lock/` while drifting out of step with it, which made it ambiguous which
file was authoritative. Recover it from git history if an opam-native lock is
ever wanted, and regenerate it with `opam lock tree-md.opam` rather than reusing
the stale copy.

The resolved versions in the tables above are the ones `dune.lock/` currently
pins, checked against `ls dune.lock/*.pkg`. Because the lock is regenerated
independently of this file, run that command after `dune pkg lock` and reconcile
the tables. The license *classes* are what the audit turns on, and a patch
version does not move one.
