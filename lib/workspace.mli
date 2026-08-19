type summary = {
  created : int;
  replaced : int;
  deleted : int;
  unchanged : int;
  (* Sources `[publish].from` left out. Reported as a count so that a vault
     which is mostly private does not say so on every line of every build. *)
  unpublished : int;
}

type result = {
  summary : summary;
  (* Addresses this build gave to trees that stated none. *)
  minted : Mint.minted list;
  diagnostics : Diagnostic.t list;
}

val check : config_path:string -> result
val build : config_path:string -> result
