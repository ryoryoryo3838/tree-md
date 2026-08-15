type t = {
  metadata : Metadata.raw;
  masked_markdown : string;
}

val parse : Source.t -> (t, Diagnostic.t list) result
