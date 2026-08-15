---
date: 2026-08-04
taxon: Note
authors:
  - "[[manual]]"
  - "Ada Lovelace"
contributors:
  - "[[index]]"
  - "Grace Hopper"
tags:
  - compiler
  - compat
meta:
  institution: "[Tsukuba](https://informatics.tsukuba.ac.jp/)"
---

# Forester 6 Compatibility

Unicode text: 日本語の文章, héllo wörld, Ελληνικά, العربية, and emoji 🎄🌲.

A paragraph with **bold**, *italic*, `code`, and hostile prose: {braces} (parens) %percent #hash, \[escaped brackets\], and a trailing backslash \\.

Native and Wiki links: [the Forester site](https://www.forester-notes.org/) and [[manual]], plus a [[notes]] subtree.

Inline math: $x^2 + y^2 = z^2$.

> A blockquote
> with **emphasis** on the second line.

Tight list:
- alpha
- beta

Loose list:

- one
- two

Ordered list starting at 7:

7. first
8. second

Inline code with hostile punctuation: `a{b}c[d]e%f` and `#include <stdio.h>`.

Fenced code with hostile punctuation:

```ocaml
let f x = { x with field = [1; 2; 3] }  (* %comment# *)
```

Hard break:\
next line.

Thematic break:

***

Display math:

$$y = mx + b$$

External image: ![External](https://example.test/img.png)

Local image: ![Plot](images/x.svg)

Direct transclusion:

![[manual]]

<!-- subtree: notes -->
## Notes

Body of the named subtree with a link back to [[index]] and inline `code`.

### Nested Anonymous Section

Anonymous subtree body with a tight list:
- one
- two
