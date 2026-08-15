type purpose = Link | Image

val validate : purpose -> Span.t -> string -> (string, Diagnostic.t) result
val percent_encode : string -> string
