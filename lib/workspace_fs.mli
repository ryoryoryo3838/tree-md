type snapshot = {
  manifest : string option;
  journal : string option;
  stage_entries : string list;
}

type fault_point =
  | After_stage
  | After_journal
  | After_output of int
  | After_manifest

exception Injected_fault of fault_point

val snapshot : output_root:string -> (snapshot, Diagnostic.t list) result
val with_build_lock : output_root:string -> (unit -> 'a) -> ('a, Diagnostic.t list) result
val writer_active : output_root:string -> (bool, Diagnostic.t list) result
val stage :
  ?inject:(fault_point -> unit) -> output_root:string ->
  journal:Transaction.t -> files:(Path_safe.relative * string) list ->
  manifest_bytes:string -> unit -> (unit, Diagnostic.t list) result
val execute :
  ?inject:(fault_point -> unit) -> output_root:string ->
  Transaction.action list -> unit -> (unit, Diagnostic.t list) result
val remove_orphan_stage : output_root:string -> (unit, Diagnostic.t list) result
