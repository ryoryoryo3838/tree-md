type t

val empty : t
val add_asset : Span.t -> routed_path:string -> t -> t
val asset_route : t -> Span.t -> string option

(** Record that the reference at [span] was written with a spelling that is not
    the identity it resolved to, so emission can substitute the identity. *)
val add_tree : Span.t -> id:string -> t -> t

val tree_id : t -> Span.t -> string option
