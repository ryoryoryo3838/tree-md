(* Reading front matter is two jobs, and they are kept apart.

   [frontmatter] is the mapping exactly as written, in the JSON data model, and
   the parser that builds it knows nothing about what any key means. mdbase
   v0.3 §03 is explicit that front matter is an arbitrary mapping, so a key
   this compiler has no use for is carried rather than rejected — an Obsidian
   vault is full of `aliases`, `cssclasses` and `created`, and none of them are
   any of tree-md's business. It is [None] when the file has no front matter at
   all, which mdbase distinguishes from having an empty one.

   Interpretation is a separate pass: Metadata.of_yaml reads the keys tree-md
   emits out of this mapping, and it happens in the compiler, where the
   collection's own settings — which key is the address, which values a type
   defaults — are known. *)
type t = {
  frontmatter : Yaml_json.t option;
  masked_markdown : string;
}

(* Warnings travel with the parsed value; only an error discards it. *)
val parse : Source.t -> (t * Diagnostic.t list, Diagnostic.t list) result
