type kind = Link | Embed

type wiki_meta = {
  wiki_kind : kind;
  wiki_body : string;
  whole_first_byte : int;
  whole_last_byte : int;
}

type candidate = {
  kind : kind;
  target : string;
  alias : string option;
  whole_span : Span.t;
  inner_span : Span.t;
}

type shape =
  | Text_shape of Span.t
  | Code_shape of Span.t
  | Shortcut_shape of candidate
  | Ordinary_link_shape of Span.t

val parse_wiki_body : string -> string * string option
val validate_wiki_body : source_path:string -> info:wiki_meta -> (string * string option, Diagnostic.t list) result
val wiki_meta_key : wiki_meta Cmarkit.Meta.key
val resolver : Source.t -> Cmarkit.Label.resolver
val shapes_for_test : Source.t -> string -> ((shape list * Diagnostic.t list), Diagnostic.t list) result
