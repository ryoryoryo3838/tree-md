type summary = {
  created : int;
  replaced : int;
  deleted : int;
  unchanged : int;
}

type result = { summary : summary; diagnostics : Diagnostic.t list }

val check : config_path:string -> result
val build : config_path:string -> result
