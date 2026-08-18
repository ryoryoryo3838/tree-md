(* A diagnostic carries two independent identifiers. [code] is tree-md's own
   stable code, which the README documents and the CLI's exit-code classes are
   derived from. [mdbase_code] is the canonical mdbase v0.3 code for the same
   condition, in lower snake_case, present only where mdbase defines one. Both
   are rendered, so a reader of either vocabulary recognises the diagnostic. *)

type severity = Error | Warning

type code =
  | TM001 | TM002 | TM003
  | TM101 | TM102 | TM103 | TM104 | TM105 | TM106 | TM107
  | TM201 | TM202 | TM203 | TM204 | TM205 | TM206
  | TM301 | TM302 | TM303 | TM304 | TM305 | TM306
  | TM401 | TM402 | TM403 | TM404 | TM500

type labelled_location = { label : string; location : Span.location }

type t = {
  severity : severity;
  code : code;
  mdbase_code : string option;
  message : string;
  primary : Span.location;
  secondary : labelled_location list;
  notes : string list;
}

val make :
  ?secondary:labelled_location list ->
  ?notes:string list ->
  ?mdbase_code:string ->
  code -> Span.location -> string -> t

(* A warning is reported and then stepped over. It never fails a build and
   never contributes to the exit code; only an error does. *)
val warn :
  ?secondary:labelled_location list ->
  ?notes:string list ->
  ?mdbase_code:string ->
  code -> Span.location -> string -> t

val is_error : t -> bool
val has_error : t list -> bool

(* The gate every compilation stage ends with: warnings travel alongside the
   value, an error discards it. Stages accumulate into one list and call this
   once, so a file still reports every diagnostic it has rather than only the
   first. *)
val gate : 'a -> t list -> ('a * t list, t list) result

val code_string : code -> string
val severity_string : severity -> string
val compare : t -> t -> int
val render : sources:(string * Source.t) list -> t -> string
