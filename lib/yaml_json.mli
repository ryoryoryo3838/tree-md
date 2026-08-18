(* Front matter as mdbase v0.3 §06 sees it: a YAML document converted into the
   JSON data model, with every value and every key carrying the source span it
   came from, so a schema violation can point at the bytes that caused it.

   The parser that builds this knows nothing about what any key means. That is
   the whole point: front matter is an arbitrary mapping, and what is required
   of it is declared by a type's JSON Schema rather than wired into the reader.
   A key tree-md has no use for is simply carried, not rejected. *)

type t = {
  value : value;
  (* The bytes a scalar was written as, before YAML resolved it to a type.
     A field tree-md reads as text uses this, so `taxon: 1.50` keeps `1.50`
     rather than being rendered back from a float as `1.5`. [None] for a list
     or a mapping. *)
  text : string option;
  span : Span.t;
}

and value =
  | Null
  | Bool of bool
  (* JSON has one number type; the two are kept apart so that JSON Schema's
     `type: integer` and `multipleOf` can mean what they say. *)
  | Int of int
  | Float of float
  | String of string
  | List of t list
  | Assoc of field list

and field = { name : string; name_span : Span.t; value : t }

(* YAML 1.2 core-schema resolution for a *plain* (unquoted) scalar. A quoted
   scalar is always a string, so this is not applied to one. *)
val resolve_plain : string -> value

(* [Error] carries the reason a value has no JSON counterpart — NaN, an
   infinity, a binary blob — which mdbase v0.3 §06 requires be rejected with a
   clear diagnostic rather than smuggled past schema validation. *)
val of_plain_scalar : string -> (value, string) result

val to_yojson : t -> Yojson.Safe.t

(* Look a key up in a mapping. [None] for any other kind of value. *)
val field : t -> string -> t option
val fields : t -> field list
val keys : t -> (string * Span.t) list

(* Build a tree from a JSON value, giving every part the same span. Used for
   values that were not written in the file at all — a `collection.read_defaults`
   entry — so the span points at the document that lacked them. *)
val of_yojson : span:Span.t -> Yojson.Safe.t -> t

(* Follow an RFC 6901 JSON Pointer to the span of the value it selects, so a
   schema issue can point at the bytes that caused it. The empty pointer
   selects the whole document. *)
val locate : t -> string -> Span.t option

(* Effective front matter: the persisted mapping plus a value for each key it
   leaves *missing*. mdbase v0.3 §07 is explicit that an explicit null is not
   missing, so a key written as null keeps its null. *)
val with_defaults : t -> (string * Yojson.Safe.t) list -> t

(* A short rendering for diagnostics: "a string", "a list", "a mapping". *)
val describe : value -> string

(* The scalar as written. [None] for a list or a mapping. *)
val as_text : t -> string option
