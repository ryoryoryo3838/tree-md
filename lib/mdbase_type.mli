(* Type files: the `_types/*.md` records mdbase v0.3 §05 defines, each pairing
   a rule for selecting records with a JSON Schema for validating them.

   What a type buys a forest is that the shape its front matter must have is
   *declared in the collection*, in the file every other mdbase tool reads,
   instead of being wired into this compiler. tree-md's own reading of the keys
   it emits — `id`, `date`, `taxon`, `authors`, `tags`, `meta` — is a separate
   concern and continues either way: those are about what it can put into a
   `.tree`, not about what the collection considers a valid record.

   A section this implementation does not act on makes the type file fail to
   load, rather than being accepted and quietly not enforced. *)

type t

val name : t -> string
val path : t -> string

(* Types declared under the configured types folder, in canonical name order.
   An absent folder is not an error: there are simply no declared types. *)
val load :
  directory:string -> config:Mdbase_config.t ->
  (t list * Diagnostic.t list, Diagnostic.t list) result

(* The types governing one record, by §07's decision process: an explicit
   declaration completes the selection, and inferred matching runs only when
   none is present. *)
val select :
  t list -> config:Mdbase_config.t -> collection_path:string ->
  frontmatter:Yojson.Safe.t -> t list * Diagnostic.t list

(* Validate raw persisted front matter against one type's schema. *)
val validate : t -> Yojson.Safe.t -> Json_schema.issue list

(* `collection.read_defaults`: effective values for keys the record leaves
   missing. An explicit null stays null, and nothing is written to the file. *)
val read_defaults : t -> (string * Yojson.Safe.t) list
