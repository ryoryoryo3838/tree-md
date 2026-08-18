(lang dune 3.22)
(name tree-md)
(version 0.1.0)
(generate_opam_files true)

(source (github ryoryoryo3838/tree-md))
(homepage "https://github.com/ryoryoryo3838/tree-md")
(bug_reports "https://github.com/ryoryoryo3838/tree-md/issues")
(license MIT)
(authors "ryoryoryo3838")
(maintainers "ryoryoryo3838 <rseimiya@miya-lis.net>")

(package
 (name tree-md)
 (synopsis "Compile strict Markdown into Forester tree source")
 (description
  "tree-md compiles a strict Markdown dialect (.tree.md) into deterministic\nForester .tree source. Headings become nested subtrees, Obsidian-style wiki\nlinks and embeds become tree references and transclusions, and every generated\nfile is manifest-owned, hash-checked, and byte-deterministic. Unsupported\nMarkdown is rejected with a stable diagnostic code rather than silently\ndropped.")
 (tags ("markdown" "forester" "transpiler" "static-site" "obsidian"))
 ; Lower bounds express the supported range; dune.lock / tree-md.opam.locked
 ; pin the exact reproducible build. alcotest is test-only and must not be
 ; forced on consumers of the library.
 (depends
  (ocaml (>= 5.3.0))
  (dune-configurator (>= 3.22.2))
  (cmarkit (>= 0.4.0))
  (yaml (>= 3.2.0))
  (otoml (>= 1.0.5))
  (cmdliner (>= 2.1.0))
  (yojson (>= 3.0.0))
  (digestif (>= 1.3.0))
  (re (>= 1.11.0))
  (alcotest (and (>= 1.9.1) :with-test))))
