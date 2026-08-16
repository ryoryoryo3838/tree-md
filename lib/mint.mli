(** Giving an address to a tree that does not state one.

    This is the only place the compiler writes to a source file. It adds an
    [id] to front matter and never touches one that is already there, so an
    address a person chose is never taken away from them. *)

type minted = { path : string; id : string }

val plan :
  Config.t -> taken:string list -> Discovery.t -> (minted list, Diagnostic.t list) result
(** Which sources have no [id], and what each would be given. Reads only. *)

val apply : minted list -> (unit, Diagnostic.t list) result
(** Write the planned addresses into their files. *)
