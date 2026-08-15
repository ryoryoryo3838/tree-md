val target : string

val escape_text_for_test : string -> string

val emit :
  resolution:Resolution.t -> Outline.t ->
  (string, Diagnostic.t list) result
