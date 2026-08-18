open Tree_md

let compile text =
  match Json_schema.compile (Yojson.Safe.from_string text) with
  | Ok schema -> schema
  | Error message -> Alcotest.fail ("schema did not compile: " ^ message)

let refuses text =
  match Json_schema.compile (Yojson.Safe.from_string text) with
  | Ok _ -> Alcotest.fail "expected the schema to be refused"
  | Error message -> message

let codes schema value =
  List.map
    (fun (issue : Json_schema.issue) -> issue.Json_schema.code)
    (Json_schema.validate schema (Yojson.Safe.from_string value))

let pointers schema value =
  List.map
    (fun (issue : Json_schema.issue) -> issue.Json_schema.pointer)
    (Json_schema.validate schema (Yojson.Safe.from_string value))

(* ── the profile boundary ──

   A keyword outside what mdbase v0.3 §06 requires is refused when the schema
   is compiled. A schema that silently means less than it says would let a
   collection report itself valid on the strength of a constraint nothing
   checked. *)

let test_unsupported_keyword_refused () =
  let message = refuses {|{"unevaluatedProperties": false}|} in
  Alcotest.(check bool) "names the keyword" true
    (String.length message > 0
     && (let needle = "unevaluatedProperties" in
         let rec find i =
           i + String.length needle <= String.length message
           && (String.sub message i (String.length needle) = needle
               || find (i + 1))
         in
         find 0))

let test_non_local_ref_refused () =
  ignore (refuses {|{"$ref": "https://example.test/schema.json"}|});
  ignore (refuses {|{"$ref": "other.json#/$defs/x"}|})

(* §07 fixes the regular-expression subset: no backreferences, no look-around. *)
let test_unsupported_regex_refused () =
  ignore (refuses {|{"pattern": "(a)\\1"}|});
  ignore (refuses {|{"pattern": "(?=a)b"}|})

let test_annotations_accepted () =
  ignore
    (compile
       {|{"title":"t","description":"d","default":1,"examples":[1],"$schema":"x"}|})

(* ── assertions ── *)

let test_type_and_required () =
  let schema =
    compile {|{"type":"object","required":["a","b"],"properties":{"a":{"type":"string"}}}|}
  in
  Alcotest.(check (list string)) "clean" [] (codes schema {|{"a":"x","b":1}|});
  Alcotest.(check (list string)) "missing key" [ "schema_required" ]
    (codes schema {|{"a":"x"}|});
  Alcotest.(check (list string)) "wrong property type" [ "schema_type" ]
    (codes schema {|{"a":1,"b":1}|});
  Alcotest.(check (list string)) "the pointer names the property" [ "/a" ]
    (pointers schema {|{"a":1,"b":1}|})

let test_additional_properties () =
  let closed =
    compile {|{"type":"object","additionalProperties":false,"properties":{"a":{}}}|}
  in
  Alcotest.(check (list string)) "closed rejects" [ "schema_additional_properties" ]
    (codes closed {|{"a":1,"b":2}|});
  let open_ =
    compile {|{"type":"object","additionalProperties":true,"properties":{"a":{}}}|}
  in
  Alcotest.(check (list string)) "open accepts" [] (codes open_ {|{"a":1,"b":2}|});
  (* Absent means true, which is what makes an Obsidian vault's extra keys
     nobody's business. *)
  let silent = compile {|{"type":"object","properties":{"a":{}}}|} in
  Alcotest.(check (list string)) "absent means open" []
    (codes silent {|{"a":1,"b":2}|})

let test_enum_const_pattern () =
  let schema =
    compile
      {|{"properties":{"s":{"enum":["draft","published"]},
                       "c":{"const":7},
                       "p":{"type":"string","pattern":"^[A-Z][0-9]+$"}}}|}
  in
  Alcotest.(check (list string)) "clean" []
    (codes schema {|{"s":"draft","c":7,"p":"A12"}|});
  Alcotest.(check (list string)) "all three fail"
    [ "schema_enum"; "schema_const"; "schema_pattern" ]
    (codes schema {|{"s":"archived","c":8,"p":"a12"}|})

let test_numbers () =
  let schema =
    compile
      {|{"properties":{"n":{"type":"number","minimum":1,"maximum":10,"multipleOf":2},
                       "x":{"exclusiveMinimum":0,"exclusiveMaximum":5}}}|}
  in
  Alcotest.(check (list string)) "clean" [] (codes schema {|{"n":4,"x":1}|});
  Alcotest.(check (list string)) "below the minimum"
    [ "schema_minimum"; "schema_multiple_of" ] (codes schema {|{"n":0.5}|});
  Alcotest.(check (list string)) "at the exclusive bound"
    [ "schema_exclusive_minimum" ] (codes schema {|{"x":0}|})

(* An integer keyword means integer: 1.0 is one, 1.5 is not. *)
let test_integer_type () =
  let schema = compile {|{"type":"integer"}|} in
  Alcotest.(check (list string)) "1.0 is an integer" [] (codes schema "1.0");
  Alcotest.(check (list string)) "1.5 is not" [ "schema_type" ] (codes schema "1.5")

(* Lengths count characters, not bytes, so a Japanese title is not four times
   as long as it looks. *)
let test_string_length_counts_characters () =
  let schema = compile {|{"type":"string","minLength":3,"maxLength":3}|} in
  Alcotest.(check (list string)) "three characters" []
    (codes schema {|"日本語"|});
  Alcotest.(check (list string)) "four characters" [ "schema_max_length" ]
    (codes schema {|"日本語版"|})

let test_arrays () =
  let schema =
    compile
      {|{"type":"array","minItems":1,"maxItems":2,"uniqueItems":true,
         "items":{"type":"string"}}|}
  in
  Alcotest.(check (list string)) "clean" [] (codes schema {|["a","b"]|});
  Alcotest.(check (list string)) "too few" [ "schema_min_items" ] (codes schema "[]");
  Alcotest.(check (list string)) "repeated" [ "schema_unique_items" ]
    (codes schema {|["a","a"]|});
  Alcotest.(check (list string)) "wrong item type" [ "schema_type" ]
    (codes schema {|[1]|});
  Alcotest.(check (list string)) "the pointer names the index" [ "/0" ]
    (pointers schema {|[1]|})

let test_combinators () =
  let any = compile {|{"anyOf":[{"type":"string"},{"type":"integer"}]}|} in
  Alcotest.(check (list string)) "one branch matches" [] (codes any {|"x"|});
  Alcotest.(check (list string)) "no branch matches" [ "schema_any_of" ]
    (codes any "true");
  let one = compile {|{"oneOf":[{"type":"string"},{"maxLength":1}]}|} in
  Alcotest.(check (list string)) "exactly one" [] (codes one "1");
  Alcotest.(check (list string)) "two branches match" [ "schema_one_of" ]
    (codes one {|"x"|});
  let all = compile {|{"allOf":[{"type":"string"},{"minLength":2}]}|} in
  Alcotest.(check (list string)) "both hold" [] (codes all {|"xy"|});
  Alcotest.(check (list string)) "one fails" [ "schema_min_length" ]
    (codes all {|"x"|})

let test_if_then_else () =
  let schema =
    compile
      {|{"if":{"properties":{"kind":{"const":"a"}},"required":["kind"]},
         "then":{"required":["a_only"]},
         "else":{"required":["other"]}}|}
  in
  Alcotest.(check (list string)) "then branch" [] (codes schema {|{"kind":"a","a_only":1}|});
  Alcotest.(check (list string)) "then branch fails" [ "schema_required" ]
    (codes schema {|{"kind":"a"}|});
  Alcotest.(check (list string)) "else branch" [] (codes schema {|{"other":1}|})

let test_defs_and_ref () =
  let schema =
    compile
      {|{"$defs":{"name":{"type":"string","minLength":1}},
         "properties":{"a":{"$ref":"#/$defs/name"}}}|}
  in
  Alcotest.(check (list string)) "clean" [] (codes schema {|{"a":"x"}|});
  Alcotest.(check (list string)) "through the ref" [ "schema_type" ]
    (codes schema {|{"a":1}|})

(* §06 requires assertion behaviour for these three formats, and RFC 3339 means
   a real calendar: 2026-02-30 is not a date. *)
let test_formats () =
  let date = compile {|{"type":"string","format":"date"}|} in
  Alcotest.(check (list string)) "a date" [] (codes date {|"2026-08-19"|});
  Alcotest.(check (list string)) "a leap day in a leap year" []
    (codes date {|"2024-02-29"|});
  Alcotest.(check (list string)) "not a leap year" [ "format_invalid" ]
    (codes date {|"2026-02-29"|});
  Alcotest.(check (list string)) "no such day" [ "format_invalid" ]
    (codes date {|"2026-02-30"|});
  let date_time = compile {|{"type":"string","format":"date-time"}|} in
  Alcotest.(check (list string)) "with Z" [] (codes date_time {|"2026-08-19T09:30:00Z"|});
  Alcotest.(check (list string)) "with an offset" []
    (codes date_time {|"2026-08-19T09:30:00+09:00"|});
  Alcotest.(check (list string)) "without one" [ "format_invalid" ]
    (codes date_time {|"2026-08-19T09:30:00"|});
  let time = compile {|{"type":"string","format":"time"}|} in
  Alcotest.(check (list string)) "a time" [] (codes time {|"09:30:00"|});
  Alcotest.(check (list string)) "hour 24" [ "format_invalid" ] (codes time {|"24:00:00"|})

let () =
  let open Alcotest in
  run "Json_schema"
    [ "profile", [
        test_case "unsupported_keyword_refused" `Quick test_unsupported_keyword_refused;
        test_case "non_local_ref_refused" `Quick test_non_local_ref_refused;
        test_case "unsupported_regex_refused" `Quick test_unsupported_regex_refused;
        test_case "annotations_accepted" `Quick test_annotations_accepted;
      ]
    ; "assertions", [
        test_case "type_and_required" `Quick test_type_and_required;
        test_case "additional_properties" `Quick test_additional_properties;
        test_case "enum_const_pattern" `Quick test_enum_const_pattern;
        test_case "numbers" `Quick test_numbers;
        test_case "integer_type" `Quick test_integer_type;
        test_case "string_length_counts_characters" `Quick test_string_length_counts_characters;
        test_case "arrays" `Quick test_arrays;
        test_case "combinators" `Quick test_combinators;
        test_case "if_then_else" `Quick test_if_then_else;
        test_case "defs_and_ref" `Quick test_defs_and_ref;
        test_case "formats" `Quick test_formats;
      ]
    ]
