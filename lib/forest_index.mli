type definition_kind = Generated_root | Generated_subtree | Handwritten_root

type definition = {
  id : string;
  kind : definition_kind;
  location : Span.location;
}

type t

val build :
  handwritten:Discovery.handwritten_root list ->
  generated:Parsed_document.t list ->
  (t, Diagnostic.t list) result

(* A build that publishes only part of its sources works out which part by
   walking the reference graph, and that has to run before anything is
   reported — so it uses an index that keeps going when two trees it will
   never publish happen to share an address. *)
val build_tolerant :
  handwritten:Discovery.handwritten_root list ->
  generated:Parsed_document.t list -> t

(* The identity a reference lands on. Which file owns that identity is left to
   the caller: when two trees share an address, the owner is exactly what is
   not yet settled. *)
val resolve_reference : t -> from:string -> string -> string option

(* The source a name would land in going by file name alone, for a target the
   index has not heard of because that source did not parse. *)
val source_of_filename : Discovery.source_file list -> string -> string option

val resolve :
  Config.forest -> t ->
  documents:Parsed_document.t list ->
  ((string * Resolution.t) list * Diagnostic.t list, Diagnostic.t list) result
