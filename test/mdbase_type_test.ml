open Tree_md

let with_directory f =
  let root = Filename.temp_file "tree-md-types" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let root = Unix.realpath root in
  let rec remove path =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Sys.remove path
    with _ -> ()
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let write_type root name contents =
  let folder = Filename.concat root "_types" in
  if not (Sys.file_exists folder) then Unix.mkdir folder 0o700;
  let channel = open_out_bin (Filename.concat folder (name ^ ".md")) in
  output_string channel contents;
  close_out channel

let load root =
  Mdbase_type.load ~directory:root ~config:Mdbase_config.default

let expect_ok name root =
  match load root with
  | Ok result -> result
  | Error diagnostics ->
    Alcotest.fail
      (name ^ ": "
       ^ String.concat "; " (List.map (fun d -> d.Diagnostic.message) diagnostics))

let expect_error name root =
  match load root with
  | Ok _ -> Alcotest.fail (name ^ ": expected an error")
  | Error diagnostics -> diagnostics

let contains haystack needle =
  let n = String.length needle in
  let rec loop i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  loop 0

let minimal ?(name = "note") ?(extra = "") () =
  "---\n\
   kind: mdbase.type\n\
   name: " ^ name ^ "\n\
   version: 1\n\
   match:\n\
  \  path_glob: \"trees-md/**/*.tree.md\"\n\
   schema:\n\
  \  dialect: json-schema-2020-12\n\
  \  value:\n\
  \    type: object\n\
  \    required: [status]\n\
  \    properties:\n\
  \      status: { type: string }\n" ^ extra ^ "---\n\n# Note\n"

let json text = Yojson.Safe.from_string text

let select types ~path ~frontmatter =
  Mdbase_type.select types ~config:Mdbase_config.default ~collection_path:path
    ~frontmatter:(json frontmatter)

(* ── loading ── *)

let test_absent_folder_is_no_types () =
  with_directory (fun root ->
    let types, warnings = expect_ok "absent" root in
    Alcotest.(check int) "none" 0 (List.length types);
    Alcotest.(check int) "silent" 0 (List.length warnings))

let test_minimal_type_loads () =
  with_directory (fun root ->
    write_type root "note" (minimal ());
    let types, _ = expect_ok "minimal" root in
    Alcotest.(check (list string)) "one type" [ "note" ]
      (List.map Mdbase_type.name types))

(* §02 permits warning about a file under the types folder that is not a type
   file. It is never read as a record either way. *)
let test_non_type_file_warns () =
  with_directory (fun root ->
    write_type root "readme" "---\ntitle: not a type\n---\n\n# Readme\n";
    let types, warnings = expect_ok "non-type" root in
    Alcotest.(check int) "no types" 0 (List.length types);
    Alcotest.(check int) "one warning" 1 (List.length warnings);
    Alcotest.(check bool) "a warning, not an error" false
      (Diagnostic.has_error warnings))

(* §05: names are compared case-insensitively, and two that differ only by case
   are conflicting definitions. *)
let test_duplicate_names_conflict () =
  with_directory (fun root ->
    write_type root "a" (minimal ~name:"note" ());
    write_type root "b" (minimal ~name:"Note" ());
    let diagnostics = expect_error "duplicates" root in
    Alcotest.(check bool) "names the type" true
      (List.exists (fun d -> contains d.Diagnostic.message "Note") diagnostics))

(* A section this implementation does not act on makes the file fail to load,
   rather than being accepted and quietly not enforced. *)
let test_unsupported_sections_refused () =
  List.iter
    (fun section ->
      with_directory (fun root ->
        write_type root "note"
          (minimal ~extra:(section ^ ":\n  on_create: {}\n") ());
        let diagnostics = expect_error section root in
        Alcotest.(check bool) (section ^ " names itself") true
          (List.exists (fun d -> contains d.Diagnostic.message section) diagnostics)))
    [ "lifecycle"; "runtime"; "migrations" ]

let test_unsupported_collection_members_refused () =
  with_directory (fun root ->
    write_type root "note"
      (minimal ~extra:"collection:\n  unique:\n    - field: id\n" ());
    let diagnostics = expect_error "unique" root in
    Alcotest.(check bool) "explains what tree-md does instead" true
      (List.exists (fun d -> contains d.Diagnostic.message "TM201") diagnostics))

(* §07: match.expr needs the cel_match profile, which tree-md does not claim. *)
let test_match_expr_refused () =
  with_directory (fun root ->
    write_type root "note"
      ("---\n\
        kind: mdbase.type\n\
        name: note\n\
        match:\n\
       \  expr:\n\
       \    $expr: 'true'\n\
        schema:\n\
       \  dialect: json-schema-2020-12\n\
       \  value:\n\
       \    type: object\n\
        ---\n");
    let diagnostics = expect_error "cel" root in
    Alcotest.(check bool) "reports unsupported_profile" true
      (List.exists
         (fun d -> d.Diagnostic.mdbase_code = Some "unsupported_profile")
         diagnostics))

let test_schema_requires_exactly_one_source () =
  with_directory (fun root ->
    write_type root "note"
      "---\nkind: mdbase.type\nname: note\nschema:\n  dialect: json-schema-2020-12\n---\n";
    ignore (expect_error "neither value nor ref" root))

(* ── read defaults ── *)

let test_read_defaults () =
  with_directory (fun root ->
    write_type root "note"
      (minimal ~extra:"collection:\n  read_defaults:\n    taxon: Note\n" ());
    let types, _ = expect_ok "defaults" root in
    Alcotest.(check (list string)) "one default" [ "taxon" ]
      (List.map fst (Mdbase_type.read_defaults (List.hd types))))

(* ── selection ── *)

let test_path_glob_selects () =
  with_directory (fun root ->
    write_type root "note" (minimal ());
    let types, _ = expect_ok "glob" root in
    let chosen, _ = select types ~path:"trees-md/a/b.tree.md" ~frontmatter:"{}" in
    Alcotest.(check int) "matched" 1 (List.length chosen);
    let missed, _ = select types ~path:"other/b.tree.md" ~frontmatter:"{}" in
    Alcotest.(check int) "not matched" 0 (List.length missed);
    (* `**` crosses separators; a single `*` does not. *)
    let shallow, _ = select types ~path:"trees-md/b.tree.md" ~frontmatter:"{}" in
    Alcotest.(check int) "** also matches an empty run" 1 (List.length shallow))

(* §07: an explicit declaration completes selection, and inferred rules are
   skipped for that record. *)
let test_explicit_declaration_wins () =
  with_directory (fun root ->
    write_type root "note" (minimal ());
    let types, _ = expect_ok "explicit" root in
    let chosen, warnings =
      select types ~path:"nowhere/x.md" ~frontmatter:{|{"type":"note"}|}
    in
    Alcotest.(check (list string)) "declared type selected" [ "note" ]
      (List.map Mdbase_type.name chosen);
    Alcotest.(check int) "silent" 0 (List.length warnings);
    let none, missing =
      select types ~path:"trees-md/x.tree.md" ~frontmatter:{|{"type":"absent"}|}
    in
    Alcotest.(check int) "inferred rules skipped" 0 (List.length none);
    Alcotest.(check int) "the unknown name is reported" 1 (List.length missing))

let test_fields_present_and_where () =
  with_directory (fun root ->
    write_type root "note"
      ("---\n\
        kind: mdbase.type\n\
        name: note\n\
        match:\n\
       \  fields_present: [status]\n\
       \  where:\n\
       \    status:\n\
       \      neq: done\n\
       \    count:\n\
       \      gte: 2\n\
        schema:\n\
       \  dialect: json-schema-2020-12\n\
       \  value:\n\
       \    type: object\n\
        ---\n");
    let types, _ = expect_ok "where" root in
    let hit, _ = select types ~path:"x" ~frontmatter:{|{"status":"open","count":3}|} in
    Alcotest.(check int) "matched" 1 (List.length hit);
    let missing_field, _ = select types ~path:"x" ~frontmatter:{|{"count":3}|} in
    Alcotest.(check int) "fields_present fails" 0 (List.length missing_field);
    let wrong, _ = select types ~path:"x" ~frontmatter:{|{"status":"done","count":3}|} in
    Alcotest.(check int) "neq fails" 0 (List.length wrong);
    let low, _ = select types ~path:"x" ~frontmatter:{|{"status":"open","count":1}|} in
    Alcotest.(check int) "gte fails" 0 (List.length low);
    (* §07: except for `exists`, an operator is false when its field is
       missing, and ordering is false for incomparable values. *)
    let absent, _ = select types ~path:"x" ~frontmatter:{|{"status":"open"}|} in
    Alcotest.(check int) "a missing operand is false" 0 (List.length absent))

let () =
  let open Alcotest in
  run "Mdbase_type"
    [ "load", [
        test_case "absent_folder_is_no_types" `Quick test_absent_folder_is_no_types;
        test_case "minimal_type_loads" `Quick test_minimal_type_loads;
        test_case "non_type_file_warns" `Quick test_non_type_file_warns;
        test_case "duplicate_names_conflict" `Quick test_duplicate_names_conflict;
        test_case "unsupported_sections_refused" `Quick test_unsupported_sections_refused;
        test_case "unsupported_collection_members_refused" `Quick
          test_unsupported_collection_members_refused;
        test_case "match_expr_refused" `Quick test_match_expr_refused;
        test_case "schema_requires_exactly_one_source" `Quick
          test_schema_requires_exactly_one_source;
        test_case "read_defaults" `Quick test_read_defaults;
      ]
    ; "select", [
        test_case "path_glob_selects" `Quick test_path_glob_selects;
        test_case "explicit_declaration_wins" `Quick test_explicit_declaration_wins;
        test_case "fields_present_and_where" `Quick test_fields_present_and_where;
      ]
    ]
