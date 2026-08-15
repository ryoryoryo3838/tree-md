type t = {
  path : string;
  start_byte : int;
  end_byte : int;
}

type location = Source_span of t | Path of string | No_location

val make : path:string -> start_byte:int -> end_byte:int -> (t, string) result
val compare : t -> t -> int
