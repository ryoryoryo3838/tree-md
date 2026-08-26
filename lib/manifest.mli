type entry = {
  source : Path_safe.relative;
  output : Path_safe.relative;
  sha256 : string;
}

type t = {
  format : int;
  compiler : string;
  target : string;
  files : entry list;
}

type operation =
  | Create of entry
  | Replace of { old_entry : entry; new_entry : entry }
  | Delete of entry
  | Unchanged of entry

val current_version : string
val of_expected : Compiler.expected list -> t
val encode : t -> string
(* [output_root] lifts a format 1 manifest, whose outputs are named below the
   output root, into the format 2 paths the rest of the compiler works in:
   every path relative to the directory holding tree-md.toml. *)
val decode :
  ?output_root:Path_safe.relative -> path:string -> string ->
  (t, Diagnostic.t list) result
val diff : old:t option -> next:t -> operation list
val sha256 : string -> string
