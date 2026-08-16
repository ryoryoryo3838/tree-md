type forest = {
  path : string;
  directory : string;
  tree_roots : (Path_safe.relative * string) list;
  asset_roots : (Path_safe.relative * string) list;
}

(* How `build` mints an address for a tree that does not state one. The
   defaults follow the convention Forester's own documentation describes: a
   base-36 number, zero-padded to four digits, chosen so that nobody is
   tempted to rename a tree the way they would one named after its title. *)
type id_scheme = Sequential | Random

type id_policy = {
  alphabet : string;
  width : int;
  scheme : id_scheme;
  prefix : string;
}

val default_id_policy : id_policy

type t = {
  path : string;
  directory : string;
  forest : forest;
  source_roots : (Path_safe.relative * string) list;
  output_root : Path_safe.relative * string;
  target : string;
  id : id_policy;
}

val load : path:string -> (t, Diagnostic.t list) result
