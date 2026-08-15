open Tree_md

let h64 c = String.make 64 c
let h_x_new = h64 '1'
let h_y_new = h64 '2'
let h_b_old = h64 '3'
let h_b_new = h64 '4'
let h_c_old = h64 '5'
let h_wrong = h64 '6'
let h_wrong2 = h64 '7'
let h_manifest = h64 '8'

let rel value =
  match Path_safe.relative value with
  | Ok relative -> relative
  | Error message -> Alcotest.fail (value ^ ": " ^ message)

let expected ~source ~output ~sha256 =
  { Compiler.source_path = "unused";
    source_config_relative = rel source;
    output_relative = rel output;
    bytes = "";
    sha256 }

let stage = ".tree-md-stage/txn-1"
let t_a_x = stage ^ "/a/x.tree.tmp"
let t_a_y = stage ^ "/a/y.tree.tmp"
let t_b = stage ^ "/b.tree.tmp"
let t_manifest = stage ^ "/manifest.tmp"

let old_manifest () =
  Manifest.of_expected
    [ expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:h_b_old;
      expected ~source:"trees-md/c.tree.md" ~output:"c.tree" ~sha256:h_c_old ]

let new_manifest () =
  Manifest.of_expected
    [ expected ~source:"trees-md/a/x.tree.md" ~output:"a/x.tree" ~sha256:h_x_new;
      expected ~source:"trees-md/a/y.tree.md" ~output:"a/y.tree" ~sha256:h_y_new;
      expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:h_b_new ]

let fixture () =
  let old = old_manifest () in
  let next = new_manifest () in
  let t =
    Transaction.create ~transaction_id:"txn-1" ~old_manifest:(Some old)
      ~new_manifest:next (Manifest.diff ~old:(Some old) ~next)
  in
  let base_h =
    match t.Transaction.base_manifest_sha256 with
    | Some hash -> hash
    | None -> Alcotest.fail "fixture: missing base manifest hash"
  in
  (t, base_h, t.Transaction.new_manifest_sha256)

let first_build_fixture () =
  let next =
    Manifest.of_expected
      [ expected ~source:"trees-md/a/x.tree.md" ~output:"a/x.tree" ~sha256:h_x_new;
        expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:h_b_new ]
  in
  let t =
    Transaction.create ~transaction_id:"txn-1" ~old_manifest:None
      ~new_manifest:next (Manifest.diff ~old:None ~next)
  in
  (t, t.Transaction.new_manifest_sha256)

let operation_string (op : Transaction.operation) =
  Printf.sprintf "%s|%s|%s|%s" (Path_safe.to_string op.Transaction.output)
    (match op.Transaction.old_sha256 with Some h -> h | None -> "-")
    (match op.Transaction.new_sha256 with Some h -> h | None -> "-")
    (match op.Transaction.temporary with
     | Some p -> Path_safe.to_string p
     | None -> "-")

let action_string = function
  | Transaction.Ensure_parent p -> "Ensure_parent " ^ Path_safe.to_string p
  | Transaction.Install_output { temporary; output; sha256 } ->
    Printf.sprintf "Install_output %s -> %s (%s)"
      (Path_safe.to_string temporary) (Path_safe.to_string output) sha256
  | Transaction.Delete_output { output; old_sha256 } ->
    Printf.sprintf "Delete_output %s (%s)"
      (Path_safe.to_string output) old_sha256
  | Transaction.Install_manifest { temporary; sha256 } ->
    Printf.sprintf "Install_manifest %s (%s)"
      (Path_safe.to_string temporary) sha256
  | Transaction.Remove_stage p -> "Remove_stage " ^ Path_safe.to_string p
  | Transaction.Remove_journal -> "Remove_journal"

let observed_of assoc path =
  match List.assoc_opt (Path_safe.to_string path) assoc with
  | None -> Transaction.Missing
  | Some hash -> Transaction.Hash hash

let check_actions name expected t ~current_manifest ~outputs ~temps =
  match
    Transaction.roll_forward t ~current_manifest
      ~output:(observed_of outputs) ~temporary:(observed_of temps)
  with
  | Error diagnostics ->
    let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
    Alcotest.fail (name ^ ": " ^ String.concat "; " messages)
  | Ok actions ->
    Alcotest.(check (list string)) name expected (List.map action_string actions)

let check_tm403 ?count name t ~current_manifest ~outputs ~temps =
  match
    Transaction.roll_forward t ~current_manifest
      ~output:(observed_of outputs) ~temporary:(observed_of temps)
  with
  | Ok _ -> Alcotest.fail (name ^ ": expected TM403")
  | Error diagnostics ->
    let codes =
      List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics
    in
    let expected =
      match count with
      | None -> [ "TM403" ]
      | Some n -> List.init n (fun _ -> "TM403")
    in
    Alcotest.(check (list string)) name expected codes

(* ── JSON building helpers (raw strings, for closed-schema decode tests) ── *)

let json_field name value = "\"" ^ name ^ "\": " ^ value

let object_json fields = "{" ^ String.concat "," fields ^ "}"

let op_json ~output ~old_sha ~new_sha ~temporary =
  Printf.sprintf
    "{\"output\": %s, \"old_sha256\": %s, \"new_sha256\": %s, \"temporary\": %s}"
    output old_sha new_sha temporary

let ops_json ops = "[" ^ String.concat "," ops ^ "]"

let default_fields ?(format = "1") ?(base = "null")
    ?(new_sha = "\"" ^ h_manifest ^ "\"")
    ?(manifest_temp = "\"" ^ t_manifest ^ "\"") ?(operations = "[]") () =
  [ json_field "format" format;
    json_field "base_manifest_sha256" base;
    json_field "new_manifest_sha256" new_sha;
    json_field "new_manifest_temporary" manifest_temp;
    json_field "operations" operations ]

let create_op ?(old_sha = "null") ?(new_sha = "\"" ^ h_x_new ^ "\"")
    ?(temporary = "\"" ^ t_a_x ^ "\"") ~output () =
  op_json ~output ~old_sha ~new_sha ~temporary

let expect_tm403 name json =
  match Transaction.decode ~path:"out/.tree-md-transaction.json" json with
  | Ok _ -> Alcotest.fail (name ^ ": expected TM403")
  | Error diagnostics ->
    let codes =
      List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics
    in
    Alcotest.(check (list string)) name ["TM403"] codes

(* ── create ── *)

let test_create_first_build_canonical () =
  let t =
    Transaction.create ~transaction_id:"txn-1" ~old_manifest:None
      ~new_manifest:(Manifest.of_expected []) (Manifest.diff ~old:None ~next:(Manifest.of_expected []))
  in
  Alcotest.(check int) "format" 1 t.Transaction.format;
  Alcotest.(check (option string)) "base is null" None
    t.Transaction.base_manifest_sha256;
  Alcotest.(check string) "new manifest hash"
    (Manifest.sha256 (Manifest.encode (Manifest.of_expected [])))
    t.Transaction.new_manifest_sha256;
  Alcotest.(check string) "manifest temporary" t_manifest
    (Path_safe.to_string t.Transaction.new_manifest_temporary);
  Alcotest.(check (list string)) "no operations" []
    (List.map operation_string t.Transaction.operations);
  let canonical =
    Printf.sprintf
      "{\n  \"format\": 1,\n  \"base_manifest_sha256\": null,\n  \"new_manifest_sha256\": \"%s\",\n  \"new_manifest_temporary\": \".tree-md-stage/txn-1/manifest.tmp\",\n  \"operations\": []\n}\n"
      (Manifest.sha256 (Manifest.encode (Manifest.of_expected [])))
  in
  Alcotest.(check string) "exact canonical bytes" canonical
    (Transaction.encode t)

let test_create_mixed_canonical () =
  let t, base_h, new_h = fixture () in
  Alcotest.(check string) "base hash" (Manifest.sha256 (Manifest.encode (old_manifest ())))
    base_h;
  Alcotest.(check string) "new hash" (Manifest.sha256 (Manifest.encode (new_manifest ())))
    new_h;
  Alcotest.(check (list string)) "operations"
    [ "a/x.tree|-|" ^ h_x_new ^ "|" ^ t_a_x;
      "a/y.tree|-|" ^ h_y_new ^ "|" ^ t_a_y;
      "b.tree|" ^ h_b_old ^ "|" ^ h_b_new ^ "|" ^ t_b;
      "c.tree|" ^ h_c_old ^ "|-|-" ]
    (List.map operation_string t.Transaction.operations);
  let canonical =
    Printf.sprintf
      "{\n  \"format\": 1,\n  \"base_manifest_sha256\": \"%s\",\n  \"new_manifest_sha256\": \"%s\",\n  \"new_manifest_temporary\": \".tree-md-stage/txn-1/manifest.tmp\",\n  \"operations\": [\n    {\n      \"output\": \"a/x.tree\",\n      \"old_sha256\": null,\n      \"new_sha256\": \"%s\",\n      \"temporary\": \".tree-md-stage/txn-1/a/x.tree.tmp\"\n    },\n    {\n      \"output\": \"a/y.tree\",\n      \"old_sha256\": null,\n      \"new_sha256\": \"%s\",\n      \"temporary\": \".tree-md-stage/txn-1/a/y.tree.tmp\"\n    },\n    {\n      \"output\": \"b.tree\",\n      \"old_sha256\": \"%s\",\n      \"new_sha256\": \"%s\",\n      \"temporary\": \".tree-md-stage/txn-1/b.tree.tmp\"\n    },\n    {\n      \"output\": \"c.tree\",\n      \"old_sha256\": \"%s\",\n      \"new_sha256\": null,\n      \"temporary\": null\n    }\n  ]\n}\n"
      base_h new_h h_x_new h_y_new h_b_old h_b_new h_c_old
  in
  Alcotest.(check string) "exact canonical bytes" canonical
    (Transaction.encode t)

let test_create_sort_invariant () =
  let old = old_manifest () in
  let next = new_manifest () in
  let diff = Manifest.diff ~old:(Some old) ~next in
  let sorted =
    Transaction.create ~transaction_id:"txn-1" ~old_manifest:(Some old)
      ~new_manifest:next diff
  in
  let reversed =
    Transaction.create ~transaction_id:"txn-1" ~old_manifest:(Some old)
      ~new_manifest:next (List.rev diff)
  in
  Alcotest.(check string) "encode invariant"
    (Transaction.encode sorted) (Transaction.encode reversed)

let test_create_skips_unchanged () =
  let manifest =
    Manifest.of_expected
      [ expected ~source:"trees-md/b.tree.md" ~output:"b.tree" ~sha256:h_b_old ]
  in
  let t =
    Transaction.create ~transaction_id:"txn-1" ~old_manifest:(Some manifest)
      ~new_manifest:manifest (Manifest.diff ~old:(Some manifest) ~next:manifest)
  in
  Alcotest.(check (list string)) "no operations" []
    (List.map operation_string t.Transaction.operations)

let test_create_invalid_id () =
  let old = old_manifest () in
  let next = new_manifest () in
  let diff = Manifest.diff ~old:(Some old) ~next in
  let expect_invalid id =
    let raised =
      try
        ignore
          (Transaction.create ~transaction_id:id ~old_manifest:(Some old)
             ~new_manifest:next diff);
        false
      with Invalid_argument _ -> true
    in
    Alcotest.(check bool) ("transaction id " ^ id) true raised
  in
  List.iter expect_invalid [ "bad/id"; ""; "a b"; ".."; "a.b"; "a\\b"; "txn 1" ]

(* ── decode round trip and sorting ── *)

let test_round_trip () =
  let t, _, _ = fixture () in
  let encoded = Transaction.encode t in
  match Transaction.decode ~path:"out/.tree-md-transaction.json" encoded with
  | Error diagnostics ->
    let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
    Alcotest.fail ("decode failed: " ^ String.concat "; " messages)
  | Ok decoded ->
    Alcotest.(check string) "encode is a fixed point" encoded
      (Transaction.encode decoded);
    Alcotest.(check (list string)) "operations preserved"
      (List.map operation_string t.Transaction.operations)
      (List.map operation_string decoded.Transaction.operations);
    Alcotest.(check string) "new manifest hash preserved"
      t.Transaction.new_manifest_sha256 decoded.Transaction.new_manifest_sha256;
    Alcotest.(check (option string)) "base hash preserved"
      t.Transaction.base_manifest_sha256
      decoded.Transaction.base_manifest_sha256;
    Alcotest.(check string) "manifest temporary preserved"
      (Path_safe.to_string t.Transaction.new_manifest_temporary)
      (Path_safe.to_string decoded.Transaction.new_manifest_temporary)

let test_decode_sorts () =
  let json =
    object_json
      (default_fields
         ~operations:(ops_json
                        [ op_json ~output:"\"c.tree\""
                            ~old_sha:("\"" ^ h_c_old ^ "\"") ~new_sha:"null"
                            ~temporary:"null";
                          op_json ~output:"\"a/x.tree\"" ~old_sha:"null"
                            ~new_sha:("\"" ^ h_x_new ^ "\"")
                            ~temporary:("\"" ^ t_a_x ^ "\"") ])
         ())
  in
  match Transaction.decode ~path:"out/.tree-md-transaction.json" json with
  | Error diagnostics ->
    let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
    Alcotest.fail ("decode failed: " ^ String.concat "; " messages)
  | Ok decoded ->
    Alcotest.(check (list string)) "operations sorted by output"
      [ "a/x.tree|-|" ^ h_x_new ^ "|" ^ t_a_x;
        "c.tree|" ^ h_c_old ^ "|-|-" ]
      (List.map operation_string decoded.Transaction.operations)

(* ── decode TM403: structure and types ── *)

let test_tm403_malformed_json () =
  expect_tm403 "malformed json" "{ not json";
  expect_tm403 "not json at all" "not-json"

let test_tm403_not_object () = expect_tm403 "not an object" "[1, 2]"

let test_tm403_unknown_field () =
  expect_tm403 "unknown field"
    (object_json (default_fields () @ [ json_field "bogus" "1" ]))

let test_tm403_duplicate_field () =
  expect_tm403 "duplicate field"
    (object_json
       (json_field "format" "1" :: json_field "format" "1"
        :: List.tl (default_fields ())))

let test_tm403_missing_fields () =
  List.iter (fun (name, fields) -> expect_tm403 name (object_json fields))
    [ "missing format", List.tl (default_fields ());
      "missing base", List.filter (fun f -> not (f = json_field "base_manifest_sha256" "null")) (default_fields ());
      "missing new sha256", List.filter (fun f -> not (f = json_field "new_manifest_sha256" ("\"" ^ h_manifest ^ "\""))) (default_fields ());
      "missing manifest temporary", List.filter (fun f -> not (f = json_field "new_manifest_temporary" ("\"" ^ t_manifest ^ "\""))) (default_fields ());
      "missing operations", List.filter (fun f -> not (f = json_field "operations" "[]")) (default_fields ()) ]

let test_tm403_format () =
  expect_tm403 "format 2" (object_json (default_fields ~format:"2" ()));
  expect_tm403 "format string" (object_json (default_fields ~format:"\"1\"" ()))

let test_tm403_base_hash () =
  expect_tm403 "base wrong type" (object_json (default_fields ~base:"1" ()));
  expect_tm403 "base invalid hash"
    (object_json (default_fields ~base:"\"abc123\"" ()))

let test_tm403_new_sha256 () =
  expect_tm403 "new sha256 null" (object_json (default_fields ~new_sha:"null" ()));
  expect_tm403 "new sha256 wrong type" (object_json (default_fields ~new_sha:"1" ()));
  expect_tm403 "new sha256 invalid hash"
    (object_json (default_fields ~new_sha:"\"abc\"" ()))

let test_tm403_manifest_temporary () =
  expect_tm403 "manifest temp wrong type"
    (object_json (default_fields ~manifest_temp:"1" ()));
  List.iter (fun temp ->
    expect_tm403 ("manifest temp " ^ temp)
      (object_json (default_fields ~manifest_temp:("\"" ^ temp ^ "\"") ())))
    [ "/abs/manifest.tmp"; "../manifest.tmp";
      ".tree-md-stage/txn-1/../manifest.tmp";
      "a\\b"; ".tree-md-stage/txn-1/manifest.tmpx";
      ".tree-md-stage/txn-1/sub/manifest.tmp";
      ".tree-md-stage/a.b/manifest.tmp";
      ".tree-md-stage/txn-1/" ]

let test_tm403_operations_wrong_type () =
  expect_tm403 "operations not an array"
    (object_json (default_fields ~operations:"{}" ()))

let test_tm403_operation_not_object () =
  expect_tm403 "operation not an object"
    (object_json (default_fields ~operations:"[1]" ()))

let test_tm403_operation_unknown_field () =
  expect_tm403 "unknown operation field"
    (object_json
       (default_fields
          ~operations:(ops_json
                         [ "{ \"output\": \"a/x.tree\", \"old_sha256\": null, \"new_sha256\": \""
                           ^ h_x_new ^ "\", \"temporary\": \"" ^ t_a_x
                           ^ "\", \"bogus\": 1 }" ])
          ()))

let test_tm403_operation_missing_fields () =
  List.iter (fun (name, op) ->
    expect_tm403 name
      (object_json (default_fields ~operations:(ops_json [ op ]) ())))
    [ "missing output",
      "{\"old_sha256\": null, \"new_sha256\": \"" ^ h_x_new
      ^ "\", \"temporary\": \"" ^ t_a_x ^ "\"}";
      "missing old_sha256",
      "{\"output\": \"a/x.tree\", \"new_sha256\": \"" ^ h_x_new
      ^ "\", \"temporary\": \"" ^ t_a_x ^ "\"}";
      "missing new_sha256",
      "{\"output\": \"a/x.tree\", \"old_sha256\": null, \"temporary\": \""
      ^ t_a_x ^ "\"}";
      "missing temporary",
      "{\"output\": \"a/x.tree\", \"old_sha256\": null, \"new_sha256\": \""
      ^ h_x_new ^ "\"}" ]

let test_tm403_operation_types () =
  expect_tm403 "output wrong type"
    (object_json
       (default_fields
          ~operations:(ops_json [ create_op ~output:"1" () ]) ()));
  expect_tm403 "old_sha256 wrong type"
    (object_json
       (default_fields
          ~operations:(ops_json [ create_op ~old_sha:"1" ~output:"\"a/x.tree\"" () ])
          ()));
  expect_tm403 "new_sha256 wrong type"
    (object_json
       (default_fields
          ~operations:(ops_json [ create_op ~new_sha:"1" ~output:"\"a/x.tree\"" () ])
          ()));
  expect_tm403 "temporary wrong type"
    (object_json
       (default_fields
          ~operations:(ops_json [ create_op ~temporary:"1" ~output:"\"a/x.tree\"" () ])
          ()));
  expect_tm403 "old_sha256 invalid hash"
    (object_json
       (default_fields
          ~operations:(ops_json [ create_op ~old_sha:"\"abc\"" ~output:"\"a/x.tree\"" () ])
          ()));
  expect_tm403 "new_sha256 invalid hash"
    (object_json
       (default_fields
          ~operations:(ops_json [ create_op ~new_sha:"\"abc\""
                                    ~output:"\"a/x.tree\"" () ])
          ()))

let test_tm403_operation_output_paths () =
  List.iter (fun output ->
    expect_tm403 ("unsafe output " ^ output)
      (object_json
         (default_fields
            ~operations:(ops_json [ create_op ~output:("\"" ^ output ^ "\"") () ])
            ())))
    [ "./a.tree"; "../a.tree"; "/a.tree"; "a\\b.tree"; "a/./b.tree";
      "a//b.tree"; "a.html"; ".tree-md-stage/x.tree"; "sub/.tree-md-x/a.tree" ]

let test_tm403_duplicate_output () =
  let ops =
    ops_json
      [ create_op ~output:"\"a/x.tree\"" ();
        op_json ~output:"\"a/x.tree\"" ~old_sha:("\"" ^ h_x_new ^ "\"")
          ~new_sha:"null" ~temporary:"null" ]
  in
  expect_tm403 "duplicate output" (object_json (default_fields ~operations:ops ()))

let test_tm403_inconsistent_null_combinations () =
  let one ~old_sha ~new_sha ~temporary name =
    expect_tm403 name
      (object_json
         (default_fields
            ~operations:(ops_json
                           [ op_json ~output:"\"a/x.tree\"" ~old_sha ~new_sha
                               ~temporary ])
            ()))
  in
  one ~old_sha:"null" ~new_sha:"null" ~temporary:"null" "all null";
  one ~old_sha:"null" ~new_sha:"null" ~temporary:("\"" ^ t_a_x ^ "\"")
    "create missing new hash";
  one ~old_sha:"null" ~new_sha:("\"" ^ h_x_new ^ "\"") ~temporary:"null"
    "create missing temporary";
  one ~old_sha:("\"" ^ h_b_old ^ "\"") ~new_sha:"null"
    ~temporary:("\"" ^ t_b ^ "\"") "delete with temporary";
  one ~old_sha:("\"" ^ h_b_old ^ "\"") ~new_sha:("\"" ^ h_b_new ^ "\"")
    ~temporary:"null" "replace missing temporary";
  one ~old_sha:("\"" ^ h_b_old ^ "\"") ~new_sha:("\"" ^ h_b_old ^ "\"")
    ~temporary:("\"" ^ t_b ^ "\"") "replace with no content change"

let test_tm403_temporary_outside_stage () =
  List.iter (fun temp ->
    expect_tm403 ("temporary " ^ temp)
      (object_json
         (default_fields
            ~operations:(ops_json
                           [ op_json ~output:"\"a/x.tree\"" ~old_sha:"null"
                               ~new_sha:("\"" ^ h_x_new ^ "\"")
                               ~temporary:("\"" ^ temp ^ "\"") ])
            ())))
    [ "a/x.tree.tmp";
      ".tree-md-stage/other-txn/a/x.tree.tmp";
      ".tree-md-stage/txn-1/a/other.tree.tmp";
      ".tree-md-stage/txn-1/a/x.tree";
      ".tree-md-stage/txn-1/a/x.tree.tmp.tmp";
      "/abs/x.tree.tmp";
      ".tree-md-stage/txn-1/a/../x.tree.tmp" ]

let test_tm403_manifest_temporary_txn_mismatch () =
  let ops =
    ops_json
      [ create_op ~output:"\"a/x.tree\"" () ]
  in
  expect_tm403 "manifest temp txn differs from operations"
    (object_json
       (default_fields ~manifest_temp:"\".tree-md-stage/other-txn/manifest.tmp\""
          ~operations:ops ()))

(* ── roll_forward: committed state ── *)

let test_committed_cleanup () =
  let t, _, new_h = fixture () in
  check_actions "committed cleanup"
    [ "Remove_stage .tree-md-stage/txn-1"; "Remove_journal" ] t
    ~current_manifest:(Transaction.Hash new_h)
    ~outputs:
      [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new ]
    ~temps: []

let test_committed_cleanup_leftover_temps () =
  let t, _, new_h = fixture () in
  check_actions "committed cleanup with leftover temps"
    [ "Remove_stage .tree-md-stage/txn-1"; "Remove_journal" ] t
    ~current_manifest:(Transaction.Hash new_h)
    ~outputs:
      [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new ]
    ~temps:
      [ t_a_x, h_x_new; t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ]

let test_committed_first_build () =
  let t, new_h = first_build_fixture () in
  check_actions "committed first build"
    [ "Remove_stage .tree-md-stage/txn-1"; "Remove_journal" ] t
    ~current_manifest:(Transaction.Hash new_h)
    ~outputs: [ "a/x.tree", h_x_new; "b.tree", h_b_new ]
    ~temps: []

(* ── roll_forward: base state, every allowed transition ── *)

let test_roll_forward_all_old () =
  let t, base_h, new_h = fixture () in
  check_actions "all operations in old state"
    [ "Ensure_parent a";
      "Install_output " ^ t_a_x ^ " -> a/x.tree (" ^ h_x_new ^ ")";
      "Install_output " ^ t_a_y ^ " -> a/y.tree (" ^ h_y_new ^ ")";
      "Install_output " ^ t_b ^ " -> b.tree (" ^ h_b_new ^ ")";
      "Delete_output c.tree (" ^ h_c_old ^ ")";
      "Install_manifest " ^ t_manifest ^ " (" ^ new_h ^ ")";
      "Remove_stage .tree-md-stage/txn-1";
      "Remove_journal" ] t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs:
      [ "b.tree", h_b_old; "c.tree", h_c_old ]
    ~temps:
      [ t_a_x, h_x_new; t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ]

let test_roll_forward_partial () =
  let t, base_h, new_h = fixture () in
  check_actions "mixed progress: some outputs already new"
    [ "Ensure_parent a";
      "Install_output " ^ t_a_y ^ " -> a/y.tree (" ^ h_y_new ^ ")";
      "Install_output " ^ t_b ^ " -> b.tree (" ^ h_b_new ^ ")";
      "Install_manifest " ^ t_manifest ^ " (" ^ new_h ^ ")";
      "Remove_stage .tree-md-stage/txn-1";
      "Remove_journal" ] t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs:
      [ "a/x.tree", h_x_new; "b.tree", h_b_old ]
    ~temps:
      [ t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ]

let test_roll_forward_replace_new_and_delete_absent () =
  let t, base_h, new_h = fixture () in
  check_actions "replace already new, delete already absent"
    [ "Ensure_parent a";
      "Install_output " ^ t_a_x ^ " -> a/x.tree (" ^ h_x_new ^ ")";
      "Install_output " ^ t_a_y ^ " -> a/y.tree (" ^ h_y_new ^ ")";
      "Install_manifest " ^ t_manifest ^ " (" ^ new_h ^ ")";
      "Remove_stage .tree-md-stage/txn-1";
      "Remove_journal" ] t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "b.tree", h_b_new ]
    ~temps:
      [ t_a_x, h_x_new; t_a_y, h_y_new; t_manifest, new_h ]

let test_roll_forward_first_build () =
  let t, new_h = first_build_fixture () in
  check_actions "first build roll forward"
    [ "Ensure_parent a";
      "Install_output " ^ t_a_x ^ " -> a/x.tree (" ^ h_x_new ^ ")";
      "Install_output " ^ t_b ^ " -> b.tree (" ^ h_b_new ^ ")";
      "Install_manifest " ^ t_manifest ^ " (" ^ new_h ^ ")";
      "Remove_stage .tree-md-stage/txn-1";
      "Remove_journal" ] t
    ~current_manifest:Transaction.Missing
    ~outputs: []
    ~temps: [ t_a_x, h_x_new; t_b, h_b_new; t_manifest, new_h ]

let test_roll_forward_first_build_partial () =
  let t, new_h = first_build_fixture () in
  check_actions "first build partial progress"
    [ "Install_output " ^ t_b ^ " -> b.tree (" ^ h_b_new ^ ")";
      "Install_manifest " ^ t_manifest ^ " (" ^ new_h ^ ")";
      "Remove_stage .tree-md-stage/txn-1";
      "Remove_journal" ] t
    ~current_manifest:Transaction.Missing
    ~outputs: [ "a/x.tree", h_x_new ]
    ~temps: [ t_b, h_b_new; t_manifest, new_h ]

(* ── roll_forward: TM403 preconditions ── *)

let test_tm403_roll_forward_output_states () =
  let t, base_h, new_h = fixture () in
  check_tm403 "create output third hash" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_wrong; "b.tree", h_b_old; "c.tree", h_c_old ]
    ~temps: [ t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ];
  check_tm403 "replace output missing" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new ]
    ~temps: [ t_manifest, new_h ];
  check_tm403 "replace output third hash" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_wrong ]
    ~temps: [ t_manifest, new_h ];
  check_tm403 "delete output third hash" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs:
      [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_old;
        "c.tree", h_wrong ]
    ~temps: [ t_b, h_b_new; t_manifest, new_h ]

let test_tm403_roll_forward_temporary_states () =
  let t, base_h, new_h = fixture () in
  check_tm403 "create missing temporary" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "b.tree", h_b_old; "c.tree", h_c_old ]
    ~temps: [ t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ];
  check_tm403 "create wrong temporary" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "b.tree", h_b_old; "c.tree", h_c_old ]
    ~temps: [ t_a_x, h_wrong; t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ];
  check_tm403 "replace missing temporary" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_old ]
    ~temps: [ t_manifest, new_h ];
  check_tm403 "replace wrong temporary" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_old ]
    ~temps: [ t_b, h_wrong; t_manifest, new_h ];
  check_tm403 "manifest temporary missing" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new ]
    ~temps: [ t_a_x, h_x_new; t_a_y, h_y_new ];
  check_tm403 "manifest temporary wrong hash" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new ]
    ~temps: [ t_a_x, h_x_new; t_a_y, h_y_new; t_b, h_b_new; t_manifest, h_wrong ]

let test_tm403_roll_forward_current_manifest () =
  let t, _, new_h = fixture () in
  check_tm403 "current manifest third hash" t
    ~current_manifest:(Transaction.Hash h_wrong2)
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new ]
    ~temps: [ t_manifest, new_h ];
  check_tm403 "current manifest missing with base" t
    ~current_manifest:Transaction.Missing
    ~outputs: [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new ]
    ~temps: [ t_manifest, new_h ];
  let first, first_new = first_build_fixture () in
  check_tm403 "first build current manifest hash" first
    ~current_manifest:(Transaction.Hash h_wrong2)
    ~outputs: [ "a/x.tree", h_x_new; "b.tree", h_b_new ]
    ~temps: [ t_manifest, first_new ];
  check_tm403 "committed output in old state" t
    ~current_manifest:(Transaction.Hash new_h)
    ~outputs:
      [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_old ]
    ~temps: [];
  check_tm403 "committed delete output present" t
    ~current_manifest:(Transaction.Hash new_h)
    ~outputs:
      [ "a/x.tree", h_x_new; "a/y.tree", h_y_new; "b.tree", h_b_new;
        "c.tree", h_c_old ]
    ~temps: []

let test_tm403_roll_forward_all_validation_before_actions () =
  let t, base_h, new_h = fixture () in
  check_tm403 ~count:2 "two output violations, both reported" t
    ~current_manifest:(Transaction.Hash base_h)
    ~outputs: [ "a/x.tree", h_wrong; "b.tree", h_wrong ]
    ~temps: [ t_a_x, h_x_new; t_a_y, h_y_new; t_b, h_b_new; t_manifest, new_h ]

let () =
  let open Alcotest in
  run "Transaction"
    [ "create", [
        test_case "first_build_canonical" `Quick test_create_first_build_canonical;
        test_case "mixed_canonical" `Quick test_create_mixed_canonical;
        test_case "sort_invariant" `Quick test_create_sort_invariant;
        test_case "skips_unchanged" `Quick test_create_skips_unchanged;
        test_case "invalid_id" `Quick test_create_invalid_id;
      ]
    ; "decode", [
        test_case "round_trip" `Quick test_round_trip;
        test_case "decode_sorts" `Quick test_decode_sorts;
      ]
    ; "tm403_decode", [
        test_case "malformed_json" `Quick test_tm403_malformed_json;
        test_case "not_object" `Quick test_tm403_not_object;
        test_case "unknown_field" `Quick test_tm403_unknown_field;
        test_case "duplicate_field" `Quick test_tm403_duplicate_field;
        test_case "missing_fields" `Quick test_tm403_missing_fields;
        test_case "format" `Quick test_tm403_format;
        test_case "base_hash" `Quick test_tm403_base_hash;
        test_case "new_sha256" `Quick test_tm403_new_sha256;
        test_case "manifest_temporary" `Quick test_tm403_manifest_temporary;
        test_case "operations_wrong_type" `Quick test_tm403_operations_wrong_type;
        test_case "operation_not_object" `Quick test_tm403_operation_not_object;
        test_case "operation_unknown_field" `Quick test_tm403_operation_unknown_field;
        test_case "operation_missing_fields" `Quick test_tm403_operation_missing_fields;
        test_case "operation_types" `Quick test_tm403_operation_types;
        test_case "operation_output_paths" `Quick test_tm403_operation_output_paths;
        test_case "duplicate_output" `Quick test_tm403_duplicate_output;
        test_case "inconsistent_null_combinations" `Quick test_tm403_inconsistent_null_combinations;
        test_case "temporary_outside_stage" `Quick test_tm403_temporary_outside_stage;
        test_case "manifest_temporary_txn_mismatch" `Quick test_tm403_manifest_temporary_txn_mismatch;
      ]
    ; "roll_forward", [
        test_case "committed_cleanup" `Quick test_committed_cleanup;
        test_case "committed_cleanup_leftover_temps" `Quick test_committed_cleanup_leftover_temps;
        test_case "committed_first_build" `Quick test_committed_first_build;
        test_case "all_old" `Quick test_roll_forward_all_old;
        test_case "partial" `Quick test_roll_forward_partial;
        test_case "replace_new_delete_absent" `Quick test_roll_forward_replace_new_and_delete_absent;
        test_case "first_build" `Quick test_roll_forward_first_build;
        test_case "first_build_partial" `Quick test_roll_forward_first_build_partial;
      ]
    ; "tm403_roll_forward", [
        test_case "output_states" `Quick test_tm403_roll_forward_output_states;
        test_case "temporary_states" `Quick test_tm403_roll_forward_temporary_states;
        test_case "current_manifest" `Quick test_tm403_roll_forward_current_manifest;
        test_case "all_validation_before_actions" `Quick test_tm403_roll_forward_all_validation_before_actions;
      ]
    ]
