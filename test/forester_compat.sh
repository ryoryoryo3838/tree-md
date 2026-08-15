#!/bin/sh
set -eu

: "${TREE_MD:?TREE_MD must name the compiler executable}"
: "${FORESTER:?FORESTER must name the pinned Forester executable}"

version=$("$FORESTER" --version)
if test "$version" != "6.0~dev"; then
  printf '%s\n' "expected Forester 6.0~dev, got $version" >&2
  exit 1
fi

fixture=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
cp -R "$fixture"/. "$tmp"/

"$TREE_MD" build --config "$tmp/tree-md.toml"
"$TREE_MD" check --config "$tmp/tree-md.toml"

if ! (cd "$tmp" && "$FORESTER" build --no-theme forest.toml) 2>"$tmp/forester.err"; then
  sed -n '1,200p' "$tmp/forester.err" >&2
  exit 1
fi

if grep -Eiq 'warning|unknown binding' "$tmp/forester.err"; then
  exit 1
fi

test -f "$tmp/output/index.html"
