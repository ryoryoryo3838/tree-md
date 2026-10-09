val target : string

val escape_text_for_test : string -> string

(** Literal text escaping shared with the public JSON emitter. *)
val escape_literal : string -> string

(** Share the existing typed attribution and literal metadata emitter. *)
val emit_metadata_fragment : Ir.inline list Metadata.t -> string

(** Emit already validated IR blocks, without title or filename fallback. *)
val emit_blocks_fragment :
  resolution:Resolution.t -> Ir.block list ->
  (string * Diagnostic.t list, Diagnostic.t list) result

val emit :
  resolution:Resolution.t -> Outline.t ->
  (string * Diagnostic.t list, Diagnostic.t list) result
