(* [filename] is the source's stem: `a/note.tree.md` gives `note`. It is a
   search key, not an address. Obsidian autocompletes and writes file names, so
   a reference may name one, but what a tree is published at is its stated `id`
   or the one a build minted for it. A stem that could not be an address —
   日本語のノート, "My Note" — is therefore no longer rejected here. *)
type source_file = {
  source_root : string;
  path : string;
  config_relative : Path_safe.relative;
  source_relative : Path_safe.relative;
  output_relative : Path_safe.relative;
  filename : string;
}

type handwritten_root = { id : string; path : string }

(* A file under a source root that is not itself a source: the images, PDFs
   and everything else a vault keeps beside its notes. Nothing here is
   published by being found — an attachment reaches the site only when a
   published tree embeds it, and only if `[assets].into` says where copies
   go. *)
type attachment = {
  path : string;
  config_relative : Path_safe.relative;
  source_relative : Path_safe.relative;
  name : string;
}

type t = {
  sources : source_file list;
  handwritten_roots : handwritten_root list;
  attachments : attachment list;
}

val scan : Config.t -> (t, Diagnostic.t list) result

val asset_matches : Config.forest -> Path_safe.relative -> string list
