type t
type utf8_error = { byte : int }

val of_string : path:string -> string -> (t, utf8_error) result
val path : t -> string
val text : t -> string
val length : t -> int
val span : t -> start_byte:int -> end_byte:int -> (Span.t, string) result
val slice : t -> Span.t -> (string, string) result
val line_col : t -> byte:int -> (int * int, string) result
val character_to_byte : t -> character:int -> int option
val excerpt : t -> Span.t -> (string * string, string) result
