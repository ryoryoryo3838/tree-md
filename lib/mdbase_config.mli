(* `mdbase.yaml`, the collection configuration mdbase v0.3 §04 defines.

   It is optional: a forest without one gets the defaults, and everything
   tree-md did before this file existed still works. What it buys is that the
   settings a collection already keeps for its other mdbase tools — how strict
   validation is, which key names declare a type, which field is the id — are
   read from one place rather than restated here. *)

(* mdbase v0.3 §04 names these "off", "warn" and "error". The last is spelled
   [Strict] here only so that it does not shadow [Result.Error]. *)
type validation = Off | Warn | Strict

type t = {
  (* The exact spec version the collection declares. Pinned, because §04 makes
     the minor component the compatibility boundary during major-zero. *)
  spec_version : string;
  validation : validation;
  types_folder : string;
  explicit_type_keys : string list;
  id_field : string;
}

val supported_spec_version : string

val default : t

(* Read `mdbase.yaml` from [directory]. Absent is not an error: the defaults
   are returned. Warnings ride along, because §04 requires an unknown
   configuration key to warn rather than fail. *)
val load :
  directory:string -> (t * Diagnostic.t list, Diagnostic.t list) result
