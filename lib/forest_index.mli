type definition_kind = Generated_root | Generated_subtree | Handwritten_root

type definition = {
  id : string;
  kind : definition_kind;
  location : Span.location;
}

type t

val build :
  handwritten:Discovery.handwritten_root list ->
  generated:Parsed_document.t list ->
  (t, Diagnostic.t list) result

val resolve :
  Config.forest -> t ->
  documents:Parsed_document.t list ->
  ((string * Resolution.t) list * Diagnostic.t list, Diagnostic.t list) result
