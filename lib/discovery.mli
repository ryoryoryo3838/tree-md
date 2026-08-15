type source_file = {
  source_root : string;
  path : string;
  config_relative : Path_safe.relative;
  source_relative : Path_safe.relative;
  output_relative : Path_safe.relative;
  root_id : string;
}

type handwritten_root = { id : string; path : string }

type t = {
  sources : source_file list;
  handwritten_roots : handwritten_root list;
}

val scan : Config.t -> (t, Diagnostic.t list) result

val asset_matches : Config.forest -> Path_safe.relative -> string list
