type purpose = Link | Image

(* A destination is two things at once. [encoded] is what goes into the output,
   because a URI reference must be percent-encoded. [written] is the path the
   note actually wrote, which is what names a file on disk: `images/日本語.png`
   is a file called 日本語.png, not one called %E6%97%A5%9C%AC.... Keeping them
   apart is what lets a note reference an asset whose name is not ASCII, or
   simply has a space in it. *)
type t = { encoded : string; written : string }

val validate : purpose -> Span.t -> string -> (t, Diagnostic.t) result
val percent_encode : string -> string
