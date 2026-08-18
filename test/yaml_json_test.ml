open Tree_md

(* Front matter reaches this module through the parser, so the tests go through
   it too rather than building trees by hand: what matters is that what the
   file says survives the trip into the JSON data model mdbase v0.3 §06
   defines. *)
let parse text =
  let source = Result.get_ok (Source.of_string ~path:"t.md" text) in
  match Frontmatter.parse source with
  | Ok (parsed, _) -> (
    match parsed.Frontmatter.frontmatter with
    | Some node -> node
    | None -> Alcotest.fail "expected front matter")
  | Error diagnostics ->
    Alcotest.fail
      ("parse failed: "
       ^ String.concat "; " (List.map (fun d -> d.Diagnostic.message) diagnostics))

let json text = Yaml_json.to_yojson (parse text)

(* ── YAML core-schema resolution ── *)

let test_scalar_resolution () =
  let node =
    parse
      "---\n\
       a: 1\n\
       b: 1.5\n\
       c: true\n\
       d: null\n\
       e: ~\n\
       f: text\n\
       g: \"1\"\n\
       ---\n"
  in
  Alcotest.(check string) "resolved into the JSON data model"
    {|{"a":1,"b":1.5,"c":true,"d":null,"e":null,"f":"text","g":"1"}|}
    (Yojson.Safe.to_string (Yaml_json.to_yojson node))

(* A quoted scalar is a string whatever it looks like. *)
let test_quoted_is_string () =
  Alcotest.(check string) "quoted number stays a string" {|{"a":"2026"}|}
    (Yojson.Safe.to_string (json "---\na: \"2026\"\n---\n"))

(* §06 requires values with no JSON counterpart to be rejected with a clear
   diagnostic rather than smuggled past schema validation. *)
let test_non_json_scalars_rejected () =
  List.iter
    (fun value ->
      let source =
        Result.get_ok (Source.of_string ~path:"t.md" ("---\na: " ^ value ^ "\n---\n"))
      in
      match Frontmatter.parse source with
      | Ok _ -> Alcotest.fail (value ^ " was accepted")
      | Error diagnostics ->
        Alcotest.(check bool) (value ^ " is TM002") true
          (List.exists
             (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM002")
             diagnostics))
    [ ".nan"; ".inf"; "-.inf" ]

(* ── the bytes as written ── *)

let test_text_is_preserved () =
  let node = parse "---\na: 1.50\n---\n" in
  Alcotest.(check (option string)) "written form kept" (Some "1.50")
    (Option.bind (Yaml_json.field node "a") Yaml_json.as_text)

(* ── JSON Pointer ── *)

let test_locate_points_at_the_value () =
  let text = "---\nouter:\n  inner: value\n---\n" in
  let node = parse text in
  match Yaml_json.locate node "/outer/inner" with
  | None -> Alcotest.fail "pointer did not resolve"
  | Some span ->
    Alcotest.(check string) "the span covers the value" "value"
      (String.sub text span.Span.start_byte
         (span.Span.end_byte - span.Span.start_byte))

let test_locate_escapes () =
  let node = parse "---\n\"a/b\": value\n---\n" in
  Alcotest.(check bool) "~1 decodes to /" true
    (Yaml_json.locate node "/a~1b" <> None)

(* A pointer that runs past the tree stops at the deepest value it reached, so
   a diagnostic still points somewhere useful. *)
let test_locate_missing_falls_back () =
  let node = parse "---\nouter: value\n---\n" in
  Alcotest.(check bool) "still resolves" true
    (Yaml_json.locate node "/outer/missing" <> None)

(* ── read defaults ── *)

let test_defaults_fill_only_missing () =
  let node = parse "---\nkept: written\nexplicit: null\n---\n" in
  let filled =
    Yaml_json.with_defaults node
      [ ("kept", `String "default"); ("explicit", `String "default");
        ("added", `String "default") ]
  in
  Alcotest.(check string) "written wins, explicit null stays, missing filled"
    {|{"kept":"written","explicit":null,"added":"default"}|}
    (Yojson.Safe.to_string (Yaml_json.to_yojson filled))

let () =
  let open Alcotest in
  run "Yaml_json"
    [ "data_model", [
        test_case "scalar_resolution" `Quick test_scalar_resolution;
        test_case "quoted_is_string" `Quick test_quoted_is_string;
        test_case "non_json_scalars_rejected" `Quick test_non_json_scalars_rejected;
        test_case "text_is_preserved" `Quick test_text_is_preserved;
      ]
    ; "pointer", [
        test_case "locate_points_at_the_value" `Quick test_locate_points_at_the_value;
        test_case "locate_escapes" `Quick test_locate_escapes;
        test_case "locate_missing_falls_back" `Quick test_locate_missing_falls_back;
      ]
    ; "defaults", [
        test_case "defaults_fill_only_missing" `Quick test_defaults_fill_only_missing;
      ]
    ]
