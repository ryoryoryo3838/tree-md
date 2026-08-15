type forest = {
  path : string;
  directory : string;
  tree_roots : (Path_safe.relative * string) list;
  asset_roots : (Path_safe.relative * string) list;
}

type t = {
  path : string;
  directory : string;
  forest : forest;
  source_roots : (Path_safe.relative * string) list;
  output_root : Path_safe.relative * string;
  target : string;
}

val load : path:string -> (t, Diagnostic.t list) result
