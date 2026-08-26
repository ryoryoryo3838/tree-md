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

(* Who fulfils a request for an address. Deciding what the address is stays
   here whatever the answer, so that a forest has one scheme rather than one
   per tool; only the writing moves. *)
type id_minter = By_build | Off

type id_policy = {
  alphabet : string;
  width : int;
  scheme : id_scheme;
  prefix : string;
  mint : id_minter;
}

val default_id_policy : id_policy

(* Where an attachment kept beside the notes is copied to, so that Forester
   has it under an asset root and `\route-asset` can name it: `[assets].into`.
   Absent means attachments are not published, which is what a forest did
   before the table existed.

   [directory] is the destination; [route_prefix] is that same directory
   relative to the one holding `forest.toml`, which is what a route carries. *)
type attachments = {
  config_relative : Path_safe.relative;
  directory : string;
  route_prefix : string;
}

type t = {
  path : string;
  directory : string;
  forest : forest;
  source_roots : (Path_safe.relative * string) list;
  output_root : Path_safe.relative * string;
  target : string;
  id : id_policy;
  (* `[publish].from`: the source-root-relative globs a build starts from.
     Empty means the table was absent, and every source is published. *)
  publish_from : string list;
  (* `[assets].into`: where an attachment a published tree reached is copied.
     None means the table was absent and no attachment is copied anywhere. *)
  attachments : attachments option;
}

val load : path:string -> (t, Diagnostic.t list) result
