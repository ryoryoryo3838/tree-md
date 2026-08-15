open Tree_md

let sha_64 =
  "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

let hash_abc =
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

let hash_empty =
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

let rel value =
  match Path_safe.relative value with
  | Ok relative -> relative
  | Error message -> Alcotest.fail (value ^ ": " ^ message)

let entry ~source ~output ~sha256 =
  { Manifest.source = rel source; Manifest.output = rel output; Manifest.sha256 = sha256 }

let expected ~source ~output ~sha256 =
  { Compiler.source_path = "unused";
    source_config_relative = rel source;
    output_relative = rel output;
    bytes = "";
    sha256 }

let entry_string (e : Manifest.entry) =
  Printf.sprintf "%s|%s|%s"
    (Path_safe.to_string e.Manifest.source)
    (Path_safe.to_string e.Manifest.output)
    e.Manifest.sha256

let files_strings (m : Manifest.t) = List.map entry_string m.Manifest.files

let operation_string = function
  | Manifest.Create e -> "Create " ^ entry_string e
  | Manifest.Replace { old_entry; new_entry } ->
    "Replace " ^ entry_string old_entry ^ " -> " ^ entry_string new_entry
  | Manifest.Delete e -> "Delete " ^ entry_string e
  | Manifest.Unchanged e -> "Unchanged " ^ entry_string e

let check_ops name expected result =
  Alcotest.(check (list string)) name expected
    (List.map operation_string result)

(* ── JSON building helpers (raw strings, for closed-schema decode tests) ── *)

let json_field name value = "\"" ^ name ^ "\": " ^ value

let object_json fields = "{" ^ String.concat "," fields ^ "}"

let default_fields ?(format = "1") ?(compiler = "\"0.1.0\"")
    ?(target = "\"" ^ Forester_6.target ^ "\"") ?(files = "[]") () =
  [ json_field "format" format;
    json_field "compiler" compiler;
    json_field "target" target;
    json_field "files" files ]

let entry_json ~source ~output ~sha256 =
  Printf.sprintf "{\"source\": %s, \"output\": %s, \"sha256\": %s}"
    source output sha256

let files_json entries = "[" ^ String.concat "," entries ^ "]"

let expect_tm402 name json =
  match Manifest.decode ~path:"out/.tree-md-manifest.json" json with
  | Ok _ -> Alcotest.fail (name ^ ": expected TM402")
  | Error diagnostics ->
    let codes =
      List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics
    in
    Alcotest.(check (list string)) name ["TM402"] codes

(* ── Canonical schema ── *)

let test_canonical_empty () =
  let manifest = Manifest.of_expected [] in
  Alcotest.(check int) "format" 1 manifest.Manifest.format;
  Alcotest.(check string) "compiler version"
    Manifest.current_version manifest.Manifest.compiler;
  Alcotest.(check string) "pinned target" Forester_6.target manifest.Manifest.target;
  Alcotest.(check (list string)) "no files" [] (files_strings manifest);
  let canonical =
    "{\n  \"format\": 1,\n  \"compiler\": \"" ^ Manifest.current_version
    ^ "\",\n  \"target\": \"" ^ Forester_6.target
    ^ "\",\n  \"files\": []\n}\n"
  in
  Alcotest.(check string) "exact canonical bytes" canonical (Manifest.encode manifest)

let test_canonical_sorted_entries () =
  let records =
    [ expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:sha_64;
      expected ~source:"trees-md/a/foo.tree.md" ~output:"a/foo.tree" ~sha256:sha_64 ]
  in
  let encoded = Manifest.encode (Manifest.of_expected records) in
  Alcotest.(check string) "sort invariant"
    (Manifest.encode (Manifest.of_expected (List.rev records))) encoded;
  let canonical =
    "{\n  \"format\": 1,\n  \"compiler\": \"" ^ Manifest.current_version
    ^ "\",\n  \"target\": \"" ^ Forester_6.target
    ^ "\",\n  \"files\": [\n    {\n      \"source\": \"trees-md/a/foo.tree.md\",\n      \"output\": \"a/foo.tree\",\n      \"sha256\": \""
    ^ sha_64
    ^ "\"\n    },\n    {\n      \"source\": \"trees-md/b.tree.md\",\n      \"output\": \"b.tree\",\n      \"sha256\": \""
    ^ sha_64
    ^ "\"\n    }\n  ]\n}\n"
  in
  Alcotest.(check string) "exact canonical bytes" canonical encoded

let test_round_trip () =
  let manifest =
    Manifest.of_expected
      [ expected ~source:"trees-md/index.tree.md" ~output:"index.tree" ~sha256:sha_64;
        expected ~source:"trees-md/child.tree.md" ~output:"child.tree" ~sha256:hash_abc ]
  in
  let encoded = Manifest.encode manifest in
  match Manifest.decode ~path:"out/.tree-md-manifest.json" encoded with
  | Error diagnostics ->
    let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
    Alcotest.fail ("decode failed: " ^ String.concat "; " messages)
  | Ok decoded ->
    Alcotest.(check string) "encode is a fixed point" encoded (Manifest.encode decoded);
    Alcotest.(check (list string)) "files preserved"
      (files_strings manifest) (files_strings decoded);
    Alcotest.(check int) "format preserved" manifest.Manifest.format decoded.Manifest.format;
    Alcotest.(check string) "compiler preserved"
      manifest.Manifest.compiler decoded.Manifest.compiler;
    Alcotest.(check string) "target preserved" manifest.Manifest.target decoded.Manifest.target

let test_decode_sorts () =
  let json =
    object_json
      (default_fields
         ~files:(files_json
                   [ entry_json ~source:"\"trees-md/b.tree.md\""
                       ~output:"\"b.tree\"" ~sha256:("\"" ^ sha_64 ^ "\"");
                     entry_json ~source:"\"trees-md/a.tree.md\""
                       ~output:"\"a.tree\"" ~sha256:("\"" ^ sha_64 ^ "\"") ])
         ())
  in
  match Manifest.decode ~path:"out/.tree-md-manifest.json" json with
  | Error diagnostics ->
    let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
    Alcotest.fail ("decode failed: " ^ String.concat "; " messages)
  | Ok decoded ->
    Alcotest.(check (list string)) "decoded files sorted by output"
      [ "trees-md/a.tree.md|a.tree|" ^ sha_64;
        "trees-md/b.tree.md|b.tree|" ^ sha_64 ]
      (files_strings decoded)

(* ── SHA-256 ── *)

let test_sha256 () =
  Alcotest.(check string) "sha256 of abc" hash_abc (Manifest.sha256 "abc");
  Alcotest.(check string) "sha256 of empty string" hash_empty (Manifest.sha256 "")

(* ── Diff ── *)

let test_diff_create () =
  let next =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:sha_64 ]
  in
  check_ops "create" [ "Create trees-md/a.tree.md|a.tree|" ^ sha_64 ]
    (Manifest.diff ~old:None ~next)

let test_diff_replace () =
  let old =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:sha_64 ]
  in
  let next =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:hash_abc ]
  in
  check_ops "replace"
    [ "Replace trees-md/a.tree.md|a.tree|" ^ sha_64
      ^ " -> trees-md/a.tree.md|a.tree|" ^ hash_abc ]
    (Manifest.diff ~old:(Some old) ~next)

let test_diff_delete () =
  let old =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:sha_64 ]
  in
  let next = Manifest.of_expected [] in
  check_ops "delete" [ "Delete trees-md/a.tree.md|a.tree|" ^ sha_64 ]
    (Manifest.diff ~old:(Some old) ~next)

let test_diff_unchanged () =
  let manifest =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:sha_64 ]
  in
  check_ops "unchanged" [ "Unchanged trees-md/a.tree.md|a.tree|" ^ sha_64 ]
    (Manifest.diff ~old:(Some manifest) ~next:manifest)

let test_diff_mixed () =
  let old =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:sha_64;
        expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:sha_64;
        expected ~source:"trees-md/d.tree.md" ~output:"d.tree" ~sha256:sha_64 ]
  in
  let next =
    Manifest.of_expected
      [ expected ~source:"trees-md/a.tree.md" ~output:"a.tree" ~sha256:sha_64;
        expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:hash_abc;
        expected ~source:"trees-md/c.tree.md" ~output:"c.tree" ~sha256:sha_64 ]
  in
  check_ops "mixed in output order"
    [ "Unchanged trees-md/a.tree.md|a.tree|" ^ sha_64;
      "Replace trees-md/b.tree.md|b.tree|" ^ sha_64
      ^ " -> trees-md/b.tree.md|b.tree|" ^ hash_abc;
      "Create trees-md/c.tree.md|c.tree|" ^ sha_64;
      "Delete trees-md/d.tree.md|d.tree|" ^ sha_64 ]
    (Manifest.diff ~old:(Some old) ~next)

(* ── Closed-schema TM402 cases ── *)

let test_tm402_malformed_json () =
  expect_tm402 "malformed json" "{ not json";
  expect_tm402 "not json at all" "not-json"

let test_tm402_not_object () = expect_tm402 "not an object" "[1, 2]"

let test_tm402_unknown_field () =
  expect_tm402 "unknown field"
    (object_json (default_fields () @ [ json_field "bogus" "1" ]))

let test_tm402_duplicate_field () =
  expect_tm402 "duplicate field"
    (object_json
       (json_field "format" "1" :: json_field "format" "1"
        :: List.tl (default_fields ())))

let test_tm402_missing_format () =
  expect_tm402 "missing format"
    (object_json (List.tl (default_fields ())))

let test_tm402_missing_compiler () =
  expect_tm402 "missing compiler"
    (object_json
       (List.filter (fun field ->
          not (String.sub field 0 (String.length "\"compiler\"")
               = "\"compiler\""))
          (default_fields ())))

let test_tm402_missing_target () =
  expect_tm402 "missing target"
    (object_json
       (List.filter (fun field ->
          not (String.sub field 0 (String.length "\"target\"")
               = "\"target\""))
          (default_fields ())))

let test_tm402_missing_files () =
  expect_tm402 "missing files"
    (object_json
       (List.filter (fun field ->
          not (String.sub field 0 (String.length "\"files\"")
               = "\"files\""))
          (default_fields ())))

let test_tm402_format_2 () =
  expect_tm402 "format 2"
    (object_json (default_fields ~format:"2" ()))

let test_tm402_format_wrong_type () =
  expect_tm402 "format string"
    (object_json (default_fields ~format:"\"1\"" ()))

let test_tm402_compiler_wrong_type () =
  expect_tm402 "compiler integer"
    (object_json (default_fields ~compiler:"1" ()))

let test_tm402_target_wrong_type () =
  expect_tm402 "target boolean"
    (object_json (default_fields ~target:"true" ()))

let test_tm402_files_wrong_type () =
  expect_tm402 "files not an array"
    (object_json (default_fields ~files:"{}" ()))

let test_tm402_entry_not_object () =
  expect_tm402 "entry not an object"
    (object_json (default_fields ~files:"[1]" ()))

let test_tm402_entry_unknown_field () =
  expect_tm402 "unknown entry field"
    (object_json
       (default_fields
          ~files:(files_json
                    [ "{ \"source\": \"trees-md/a.tree.md\", \"output\": \"a.tree\", \"sha256\": \""
                      ^ sha_64 ^ "\", \"bogus\": 1 }" ])
          ()))

let test_tm402_entry_missing_sha256 () =
  expect_tm402 "missing entry sha256"
    (object_json
       (default_fields
          ~files:(files_json
                    [ "{ \"source\": \"trees-md/a.tree.md\", \"output\": \"a.tree\" }" ])
          ()))

let test_tm402_duplicate_source () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"a.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"");
        entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"b.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"") ]
  in
  expect_tm402 "duplicate source" (object_json (default_fields ~files ()))

let test_tm402_duplicate_output () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"a.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"");
        entry_json ~source:"\"trees-md/b.tree.md\"" ~output:"\"a.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"") ]
  in
  expect_tm402 "duplicate output" (object_json (default_fields ~files ()))

let test_tm402_uppercase_hash () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"a.tree\""
          ~sha256:("\"" ^ String.uppercase_ascii sha_64 ^ "\"") ]
  in
  expect_tm402 "uppercase hash" (object_json (default_fields ~files ()))

let test_tm402_short_hash () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"a.tree\""
          ~sha256:"\"abc123\"" ]
  in
  expect_tm402 "short hash" (object_json (default_fields ~files ()))

let test_tm402_hash_wrong_type () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"a.tree\""
          ~sha256:"1" ]
  in
  expect_tm402 "hash not a string" (object_json (default_fields ~files ()))

let test_tm402_absolute_path () =
  let files =
    files_json
      [ entry_json ~source:"\"/abs/a.tree.md\"" ~output:"\"a.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"") ]
  in
  expect_tm402 "absolute source" (object_json (default_fields ~files ()));
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"/abs/a.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"") ]
  in
  expect_tm402 "absolute output" (object_json (default_fields ~files ()))

let test_tm402_dot_and_dotdot_path () =
  let outputs = [ "./a.tree"; "a/./b.tree"; "../a.tree"; "a/../b.tree"; "a\\\\b.tree" ] in
  List.iter (fun output ->
    let files =
      files_json
        [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:("\"" ^ output ^ "\"")
            ~sha256:("\"" ^ sha_64 ^ "\"") ]
    in
    expect_tm402 ("unsafe output path " ^ output)
      (object_json (default_fields ~files ())))
    outputs

let test_tm402_non_tree_output () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:"\"a.html\""
          ~sha256:("\"" ^ sha_64 ^ "\"") ]
  in
  expect_tm402 "non .tree output" (object_json (default_fields ~files ()))

let test_tm402_non_tree_md_source () =
  let files =
    files_json
      [ entry_json ~source:"\"trees-md/a.md\"" ~output:"\"a.tree\""
          ~sha256:("\"" ^ sha_64 ^ "\"") ]
  in
  expect_tm402 "non .tree.md source" (object_json (default_fields ~files ()))

let test_tm402_tree_md_component () =
  let outputs = [ ".tree-md-stage/a.tree"; "sub/.tree-md-x/a.tree" ] in
  List.iter (fun output ->
    let files =
      files_json
        [ entry_json ~source:"\"trees-md/a.tree.md\"" ~output:("\"" ^ output ^ "\"")
            ~sha256:("\"" ^ sha_64 ^ "\"") ]
    in
    expect_tm402 ("reserved .tree-md component " ^ output)
      (object_json (default_fields ~files ())))
    outputs

let () =
  let open Alcotest in
  run "Manifest"
    [ "canonical_schema", [
        test_case "canonical_empty" `Quick test_canonical_empty;
        test_case "canonical_sorted_entries" `Quick test_canonical_sorted_entries;
        test_case "round_trip" `Quick test_round_trip;
        test_case "decode_sorts" `Quick test_decode_sorts;
      ]
    ; "sha256", [
        test_case "sha256" `Quick test_sha256;
      ]
    ; "diff", [
        test_case "create" `Quick test_diff_create;
        test_case "replace" `Quick test_diff_replace;
        test_case "delete" `Quick test_diff_delete;
        test_case "unchanged" `Quick test_diff_unchanged;
        test_case "mixed" `Quick test_diff_mixed;
      ]
    ; "tm402", [
        test_case "malformed_json" `Quick test_tm402_malformed_json;
        test_case "not_object" `Quick test_tm402_not_object;
        test_case "unknown_field" `Quick test_tm402_unknown_field;
        test_case "duplicate_field" `Quick test_tm402_duplicate_field;
        test_case "missing_format" `Quick test_tm402_missing_format;
        test_case "missing_compiler" `Quick test_tm402_missing_compiler;
        test_case "missing_target" `Quick test_tm402_missing_target;
        test_case "missing_files" `Quick test_tm402_missing_files;
        test_case "format_2" `Quick test_tm402_format_2;
        test_case "format_wrong_type" `Quick test_tm402_format_wrong_type;
        test_case "compiler_wrong_type" `Quick test_tm402_compiler_wrong_type;
        test_case "target_wrong_type" `Quick test_tm402_target_wrong_type;
        test_case "files_wrong_type" `Quick test_tm402_files_wrong_type;
        test_case "entry_not_object" `Quick test_tm402_entry_not_object;
        test_case "entry_unknown_field" `Quick test_tm402_entry_unknown_field;
        test_case "entry_missing_sha256" `Quick test_tm402_entry_missing_sha256;
        test_case "duplicate_source" `Quick test_tm402_duplicate_source;
        test_case "duplicate_output" `Quick test_tm402_duplicate_output;
        test_case "uppercase_hash" `Quick test_tm402_uppercase_hash;
        test_case "short_hash" `Quick test_tm402_short_hash;
        test_case "hash_wrong_type" `Quick test_tm402_hash_wrong_type;
        test_case "absolute_path" `Quick test_tm402_absolute_path;
        test_case "dot_and_dotdot_path" `Quick test_tm402_dot_and_dotdot_path;
        test_case "non_tree_output" `Quick test_tm402_non_tree_output;
        test_case "non_tree_md_source" `Quick test_tm402_non_tree_md_source;
        test_case "tree_md_component" `Quick test_tm402_tree_md_component;
      ]
    ]
