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
val decode : path:string -> string -> (t, Diagnostic.t list) result
val diff : old:t option -> next:t -> operation list
val sha256 : string -> string
