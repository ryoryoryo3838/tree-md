type relative

val relative : string -> (relative, string) result
val to_string : relative -> string
val append : relative -> relative -> relative
val basename : relative -> string
val resolve : base:string -> relative -> string

(* Lexical normalisation of a path that may carry `..`, with no safety promise
   of its own — pair it with [is_within] to bound the result. A schema
   reference is the case that needs it: mdbase v0.3 §06 lets one point outward
   with `../`, and settles safety by requiring the resolved file to stay inside
   the root that owns it. *)
val normalize_absolute : string -> string

val is_within : root:string -> string -> bool
