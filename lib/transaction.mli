type operation = {
  output : Path_safe.relative;
  old_sha256 : string option;
  new_sha256 : string option;
  temporary : Path_safe.relative option;
}

type t = {
  format : int;
  base_manifest_sha256 : string option;
  new_manifest_sha256 : string;
  new_manifest_temporary : Path_safe.relative;
  operations : operation list;
}

type observed = Missing | Hash of string
type action =
  | Ensure_parent of Path_safe.relative
  | Install_output of { temporary : Path_safe.relative; output : Path_safe.relative; sha256 : string }
  | Delete_output of { output : Path_safe.relative; old_sha256 : string }
  | Install_manifest of { temporary : Path_safe.relative; sha256 : string }
  | Remove_stage of Path_safe.relative
  | Remove_journal

val create :
  transaction_id:string -> old_manifest:Manifest.t option ->
  new_manifest:Manifest.t -> Manifest.operation list -> t
val encode : t -> string
val decode : path:string -> string -> (t, Diagnostic.t list) result
val roll_forward :
  t -> current_manifest:observed ->
  output:(Path_safe.relative -> observed) ->
  temporary:(Path_safe.relative -> observed) ->
  (action list, Diagnostic.t list) result
