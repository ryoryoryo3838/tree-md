type relative

val relative : string -> (relative, string) result
val to_string : relative -> string
val append : relative -> relative -> relative
val basename : relative -> string
val resolve : base:string -> relative -> string
val is_within : root:string -> string -> bool
