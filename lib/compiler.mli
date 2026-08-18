type expected = {
  source_path : string;
  source_config_relative : Path_safe.relative;
  output_relative : Path_safe.relative;
  bytes : string;
  sha256 : string;
}

(* Every stage returns its warnings alongside the value it produced. Only an
   error discards the value, so a document that merely warned still compiles. *)
(* [default_id] is the identity to compile under when the front matter states
   none; [filename] is the source's stem, which an absent H1 titles the tree
   with. *)
(* What the collection declares about its records: `mdbase.yaml` and the type
   files under its types folder. A forest with neither gets [no_mdbase] and
   behaves exactly as it did before they existed. *)
type mdbase = {
  settings : Mdbase_config.t;
  types : Mdbase_type.t list;
}

val no_mdbase : mdbase
val load_mdbase : Config.t -> (mdbase * Diagnostic.t list, Diagnostic.t list) result

(* [collection_path] is the source's path relative to the collection root,
   which is what a type's `match.path_glob` is matched against. *)
val parse :
  ?mdbase:mdbase -> ?collection_path:string ->
  default_id:string -> filename:string -> Source.t ->
  (Parsed_document.t * Diagnostic.t list, Diagnostic.t list) result

val emit :
  resolution:Resolution.t -> Parsed_document.t ->
  (string * Diagnostic.t list, Diagnostic.t list) result

val identities :
  ?mdbase:mdbase -> Config.t -> Discovery.t ->
  (string list, Diagnostic.t list) result
(** Every name the forest already answers to: stated ids, file names, subtree
    ids and handwritten roots. What a newly minted address must miss. *)

(* [allow_pending] tolerates a tree that has no address yet. It is set only
   for the compile that precedes minting, which exists to prove the forest is
   sound before anything is rewritten. Everywhere else — `check`, and every
   compile after minting — an unaddressed tree is TM206. *)
val compile_forest :
  ?allow_pending:bool -> ?mdbase:mdbase -> Config.t -> Discovery.t ->
  (expected list * Diagnostic.t list, Diagnostic.t list) result
