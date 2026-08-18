(** Giving an address to a tree that does not state one.

    This is the only place the compiler writes to a source file. It adds an
    [id] to front matter and never touches one that is already there, so an
    address a person chose is never taken away from them. *)

type minted = { path : string; id : string }

val plan :
  ?id_field:string ->
  Config.t -> taken:string list -> Discovery.t -> (minted list, Diagnostic.t list) result
(** Which sources have no address, and what each would be given. Reads only.
    [id_field] is `settings.id_field` from mdbase.yaml, defaulting to [id]. *)

val apply : ?id_field:string -> minted list -> (unit, Diagnostic.t list) result
(** Write the planned addresses into their files, under the key the collection
    addresses records by. *)
