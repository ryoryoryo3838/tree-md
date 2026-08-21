(* The JSON Schema 2020-12 keywords mdbase v0.3 §06 requires of a Core Read
   implementation, and no others.

   A keyword outside the profile is refused when the schema is compiled rather
   than ignored when a record is validated. A schema that silently means less
   than it says is worse than one that will not load: the collection would
   report itself valid on the strength of a constraint nothing checked. *)

type t

(* One failed assertion. [pointer] is an RFC 6901 JSON Pointer into the
   validated value; [code] is mdbase's canonical lower_snake_case code for the
   keyword that failed, as §06 defines it — `required` gives `schema_required`,
   `additionalProperties` gives `schema_additional_properties`. *)
type issue = {
  pointer : string;
  code : string;
  message : string;
}

(* [Error] carries the reason the schema itself is not usable: an unsupported
   keyword, a malformed one, an unresolvable or cyclic local `$ref`. *)
val compile : Yojson.Safe.t -> (t, string) result

val validate : t -> Yojson.Safe.t -> issue list

(* The keywords this profile asserts, for diagnostics and documentation. *)
val supported_keywords : string list
