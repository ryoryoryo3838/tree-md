open Tree_md

let target = "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"

let valid_tree_md =
  "version = 1\n" ^
  "forest = \"forest/forest.toml\"\n" ^
  "sources = [\"sources/trees\", \"sources/notes\"]\n" ^
  "output = \"forest/generated\"\n" ^
  "target = \"" ^ target ^ "\"\n"

let valid_forest =
  "[forest]\n" ^
  "trees = [\"generated\", \"handwritten\"]\n" ^
  "assets = [\"assets\"]\n"

let fixture_path relative =
  let executable_directory = Filename.dirname (Unix.realpath Sys.executable_name) in
  let build_root =
    executable_directory
    |> Filename.dirname
    |> Filename.dirname
    |> Filename.dirname
    |> Filename.dirname
    |> Filename.dirname
  in
  let candidates = [
    Filename.concat "fixtures" relative;
    Filename.concat "tools/tree-md/test/fixtures" relative;
    Filename.concat build_root ("tools/tree-md/test/fixtures/" ^ relative);
  ] in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> Unix.realpath path
  | None -> failwith ("fixture not found: " ^ relative)

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let with_temp_project tree_contents forest_contents f =
  let root = Filename.temp_file "tree-md-config-" ".dir" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let forest_directory = Filename.concat root "forest" in
  Unix.mkdir forest_directory 0o700;
  let tree_path = Filename.concat root "tree-md.toml" in
  let forest_path = Filename.concat forest_directory "forest.toml" in
  write_file tree_path tree_contents;
  write_file forest_path forest_contents;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove tree_path;
      Sys.remove forest_path;
      Unix.rmdir forest_directory;
      Unix.rmdir root)
    (fun () -> f tree_path)

let with_different_cwd f =
  let directory = Filename.temp_file "tree-md-cwd-" ".dir" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let original = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () -> Sys.chdir original; Unix.rmdir directory)
    (fun () -> Sys.chdir directory; f ())

let expect_tm401 name result =
  match result with
  | Ok _ -> Alcotest.fail (name ^ ": expected TM401")
  | Error diagnostics ->
    let has_tm401 diagnostic =
      Diagnostic.code_string diagnostic.Diagnostic.code = "TM401"
    in
    Alcotest.(check bool) name true (List.exists has_tm401 diagnostics)

let expect_relative value =
  match Path_safe.relative value with
  | Ok relative -> relative
  | Error message -> Alcotest.fail (value ^ ": " ^ message)

let test_relative_rejects_unsafe_paths () =
  let invalid = [""; "/absolute"; "a//b"; "a/"; "a/./b"; "a/../b";
                 "a\\b"; "a\000b"; "C:/absolute"] in
  List.iter (fun value ->
    match Path_safe.relative value with
    | Ok _ -> Alcotest.fail ("accepted unsafe path: " ^ value)
    | Error _ -> ()) invalid

let test_relative_operations () =
  let first = expect_relative "a/b" in
  let second = expect_relative "c/d.txt" in
  Alcotest.(check string) "to_string" "a/b" (Path_safe.to_string first);
  Alcotest.(check string) "append" "a/b/c/d.txt"
    (Path_safe.to_string (Path_safe.append first second));
  Alcotest.(check string) "basename" "d.txt" (Path_safe.basename second);
  Alcotest.(check string) "resolve" "/tmp/project/src/a/b"
    (Path_safe.resolve ~base:"/tmp/project/./src" first);
  Alcotest.(check bool) "within child" true
    (Path_safe.is_within ~root:"/tmp/project/src" "/tmp/project/src/a/b");
  Alcotest.(check bool) "within root" true
    (Path_safe.is_within ~root:"/tmp/project/src" "/tmp/project/src");
  Alcotest.(check bool) "not a prefix sibling" false
    (Path_safe.is_within ~root:"/tmp/project/src" "/tmp/project/src-old")

let pair_strings pairs =
  List.map (fun (relative, resolved) ->
    (Path_safe.to_string relative, resolved)) pairs

let test_valid_path_bases () =
  let config_path = fixture_path "config/valid/tree-md.toml" in
  let config_directory = Filename.dirname config_path in
  let forest_directory = config_directory in
  with_different_cwd (fun () ->
    match Config.load ~path:config_path with
    | Error diagnostics ->
      let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
      Alcotest.fail (String.concat "; " messages)
    | Ok config ->
      Alcotest.(check string) "config path" config_path config.Config.path;
      Alcotest.(check string) "config directory" config_directory config.directory;
      Alcotest.(check string) "target" Forester_6.target config.target;
      Alcotest.(check string) "forest path"
        (Filename.concat forest_directory "forest.toml") config.forest.path;
      Alcotest.(check string) "forest directory" forest_directory config.forest.directory;
      Alcotest.(check (list (pair string string))) "source bases"
        [ ("sources/trees", Filename.concat config_directory "sources/trees");
          ("sources/notes", Filename.concat config_directory "sources/notes") ]
        (pair_strings config.source_roots);
      Alcotest.(check (pair string string)) "output base"
        ("generated", Filename.concat config_directory "generated")
        (let relative, resolved = config.output_root in
         (Path_safe.to_string relative, resolved));
      Alcotest.(check (list (pair string string))) "forest tree bases"
        [ ("generated", Filename.concat forest_directory "generated");
          ("handwritten", Filename.concat forest_directory "handwritten") ]
        (pair_strings config.forest.tree_roots);
      Alcotest.(check (list (pair string string))) "forest asset bases"
        [ ("assets", Filename.concat forest_directory "assets") ]
        (pair_strings config.forest.asset_roots))

let test_valid_nested_forest_path_bases () =
  let config_path = fixture_path "config/nested/tree-md.toml" in
  let config_directory = Filename.dirname config_path in
  let forest_directory = Filename.concat config_directory "forest" in
  with_different_cwd (fun () ->
    match Config.load ~path:config_path with
    | Error diagnostics ->
      let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
      Alcotest.fail (String.concat "; " messages)
    | Ok config ->
      Alcotest.(check string) "config path" config_path config.Config.path;
      Alcotest.(check string) "config directory" config_directory config.directory;
      Alcotest.(check string) "forest path"
        (Filename.concat forest_directory "forest.toml") config.forest.path;
      Alcotest.(check string) "forest directory" forest_directory config.forest.directory;
      Alcotest.(check (list (pair string string))) "source bases"
        [ ("sources/trees", Filename.concat config_directory "sources/trees");
          ("sources/notes", Filename.concat config_directory "sources/notes") ]
        (pair_strings config.source_roots);
      Alcotest.(check (pair string string)) "output base"
        ("forest/generated", Filename.concat forest_directory "generated")
        (let relative, resolved = config.output_root in
         (Path_safe.to_string relative, resolved));
      Alcotest.(check (list (pair string string))) "forest tree bases"
        [ ("generated", Filename.concat forest_directory "generated");
          ("handwritten", Filename.concat forest_directory "handwritten") ]
        (pair_strings config.forest.tree_roots);
      Alcotest.(check (list (pair string string))) "forest asset bases"
        [ ("assets", Filename.concat forest_directory "assets") ]
        (pair_strings config.forest.asset_roots))

let test_missing_file () =
  let path = Filename.concat (Filename.get_temp_dir_name ()) "tree-md-missing.toml" in
  expect_tm401 "missing file" (Config.load ~path)

let test_wrong_version () =
  let contents = "version = 2\n" ^ String.sub valid_tree_md 12 (String.length valid_tree_md - 12) in
  with_temp_project contents valid_forest (fun path ->
    expect_tm401 "wrong version" (Config.load ~path))

let test_unknown_field () =
  with_temp_project (valid_tree_md ^ "extra = true\n") valid_forest (fun path ->
    expect_tm401 "unknown field" (Config.load ~path))

let test_missing_field () =
  let contents =
    "version = 1\nforest = \"forest/forest.toml\"\n" ^
    "sources = [\"sources/trees\"]\noutput = \"forest/generated\"\n"
  in
  with_temp_project contents valid_forest (fun path ->
    expect_tm401 "missing field" (Config.load ~path))

let test_unsupported_target () =
  let contents =
    "version = 1\nforest = \"forest/forest.toml\"\n" ^
    "sources = [\"sources/trees\"]\noutput = \"forest/generated\"\n" ^
    "target = \"unsupported\"\n"
  in
  with_temp_project contents valid_forest (fun path ->
    expect_tm401 "unsupported target" (Config.load ~path))

let tree_md_with_sources sources =
  "version = 1\nforest = \"forest/forest.toml\"\n" ^
  "sources = " ^ sources ^ "\noutput = \"forest/generated\"\n" ^
  "target = \"" ^ target ^ "\"\n"

let test_absolute_path () =
  with_temp_project (tree_md_with_sources "[\"/outside\"]") valid_forest (fun path ->
    expect_tm401 "absolute path" (Config.load ~path))

let test_empty_segment () =
  with_temp_project (tree_md_with_sources "[\"a//b\"]") valid_forest (fun path ->
    expect_tm401 "empty segment" (Config.load ~path))

let test_dot_segment () =
  with_temp_project (tree_md_with_sources "[\".\"]") valid_forest (fun path ->
    expect_tm401 "dot segment" (Config.load ~path))

let test_dot_dot_segment () =
  with_temp_project (tree_md_with_sources "[\"..\"]") valid_forest (fun path ->
    expect_tm401 "dot-dot segment" (Config.load ~path))

let test_backslash_path () =
  with_temp_project (tree_md_with_sources "[\"a\\\\b\"]") valid_forest (fun path ->
    expect_tm401 "backslash path" (Config.load ~path))

let test_source_output_overlap () =
  with_temp_project (tree_md_with_sources "[\"forest\"]") valid_forest (fun path ->
    expect_tm401 "source/output overlap" (Config.load ~path))

let test_duplicate_source_root () =
  with_temp_project (tree_md_with_sources "[\"sources/trees\", \"sources/trees\"]")
    valid_forest (fun path -> expect_tm401 "duplicate source" (Config.load ~path))

let test_output_absent_from_forest_trees () =
  let forest = "[forest]\ntrees = [\"handwritten\"]\nassets = [\"assets\"]\n" in
  with_temp_project valid_tree_md forest (fun path ->
    expect_tm401 "output absent from trees" (Config.load ~path))

let test_non_string_tree_member () =
  let forest = "[forest]\ntrees = [1]\nassets = [\"assets\"]\n" in
  with_temp_project valid_tree_md forest (fun path ->
    expect_tm401 "non-string tree member" (Config.load ~path))

let test_non_string_asset_member () =
  let forest = "[forest]\ntrees = [\"generated\"]\nassets = [true]\n" in
  with_temp_project valid_tree_md forest (fun path ->
    expect_tm401 "non-string asset member" (Config.load ~path))

let test_syntax_error_is_path_prefixed () =
  with_temp_project "version =\n" valid_forest (fun path ->
    match Config.load ~path with
    | Ok _ -> Alcotest.fail "syntax error unexpectedly accepted"
    | Error [diagnostic] ->
      Alcotest.(check bool) "syntax path prefix" true
        (String.length diagnostic.Diagnostic.message >= String.length path
         && String.sub diagnostic.message 0 (String.length path) = path)
    | Error diagnostics ->
      Alcotest.fail (Printf.sprintf "expected one diagnostic, got %d"
                       (List.length diagnostics)))

let () =
  let open Alcotest in
  run "Config"
    [ "paths", [
        test_case "relative_rejects_unsafe_paths" `Quick test_relative_rejects_unsafe_paths;
        test_case "relative_operations" `Quick test_relative_operations;
        test_case "valid_path_bases" `Quick test_valid_path_bases;
        test_case "valid_nested_forest_path_bases" `Quick test_valid_nested_forest_path_bases;
      ]
    ; "invalid", [
        test_case "missing_file" `Quick test_missing_file;
        test_case "wrong_version" `Quick test_wrong_version;
        test_case "unknown_field" `Quick test_unknown_field;
        test_case "missing_field" `Quick test_missing_field;
        test_case "unsupported_target" `Quick test_unsupported_target;
        test_case "absolute_path" `Quick test_absolute_path;
        test_case "empty_segment" `Quick test_empty_segment;
        test_case "dot_segment" `Quick test_dot_segment;
        test_case "dot_dot_segment" `Quick test_dot_dot_segment;
        test_case "backslash_path" `Quick test_backslash_path;
        test_case "source_output_overlap" `Quick test_source_output_overlap;
        test_case "duplicate_source_root" `Quick test_duplicate_source_root;
        test_case "output_absent_from_forest_trees" `Quick test_output_absent_from_forest_trees;
        test_case "non_string_tree_member" `Quick test_non_string_tree_member;
        test_case "non_string_asset_member" `Quick test_non_string_asset_member;
        test_case "syntax_error_is_path_prefixed" `Quick test_syntax_error_is_path_prefixed;
      ]
    ]
