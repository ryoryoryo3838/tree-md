type severity = Error

type code =
  | TM001 | TM002 | TM003
  | TM101 | TM102 | TM103 | TM104 | TM105 | TM106 | TM107
  | TM201 | TM202 | TM203 | TM204 | TM205
  | TM301 | TM302 | TM303 | TM304 | TM305 | TM306
  | TM401 | TM402 | TM403 | TM404 | TM500

type labelled_location = { label : string; location : Span.location }

type t = {
  severity : severity;
  code : code;
  message : string;
  primary : Span.location;
  secondary : labelled_location list;
  notes : string list;
}

val make :
  ?secondary:labelled_location list ->
  ?notes:string list ->
  code -> Span.location -> string -> t
val code_string : code -> string
val compare : t -> t -> int
val render : sources:(string * Source.t) list -> t -> string
