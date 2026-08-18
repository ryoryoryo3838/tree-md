open Tree_md

let relative value =
  match Path_safe.relative value with
  | Ok relative -> relative
  | Error message -> Alcotest.fail (value ^ ": " ^ message)

let contains haystack needle =
  let needle_length = String.length needle in
  let rec loop i =
    i + needle_length <= String.length haystack
    && (String.sub haystack i needle_length = needle || loop (i + 1))
  in
  loop 0

let write_file path contents =
  let directory = Filename.dirname path in
  let rec mkdirs path =
    if not (Sys.file_exists path) then begin
      if Filename.dirname path <> path then mkdirs (Filename.dirname path);
      Unix.mkdir path 0o755
    end
  in
  mkdirs directory;
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel contents)

let resolve base path = Path_safe.resolve ~base (relative path)

let make_config ~root ~sources ~tree_roots ~asset_roots ~output =
  let pairs names =
    List.map (fun name -> (relative name, resolve root name)) names
  in
  ({
     Config.path = Filename.concat root "tree-md.toml";
     directory = root;
     forest = {
       path = Filename.concat root "forest.toml";
       directory = root;
       tree_roots = pairs tree_roots;
       asset_roots = pairs asset_roots;
     };
     source_roots = pairs sources;
     output_root = (relative output, resolve root output);
     target = Forester_6.target;
     id = Config.default_id_policy;
   } : Config.t)

let with_fixture f =
  let root = Filename.temp_file "tree-md-discovery-" ".dir" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let rec remove path =
    try
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> remove (Filename.concat path name))
          (Sys.readdir path);
        Unix.rmdir path
      | _ -> Sys.remove path
    with _ -> ()
  in
  Fun.protect
    ~finally:(fun () -> remove root)
    (fun () -> f root)

let standard_fixture ~root =
  write_file (Filename.concat root "trees-md/a/foo.tree.md") "foo body\n";
  write_file (Filename.concat root "trees-md/b/bar.tree.md") "bar body\n";
  write_file (Filename.concat root "trees-md/ignored.md") "not a tree\n";
  write_file (Filename.concat root "trees-md/.hidden.tree.md") "hidden file\n";
  write_file (Filename.concat root "trees-md/.hidden/note.tree.md") "hidden dir\n";
  write_file (Filename.concat root "trees/manual.tree") "manual tree\n";
  write_file (Filename.concat root "generated/old.tree") "old generated\n";
  write_file (Filename.concat root "assets/images/x.png") "image\n";
  write_file (Filename.concat root "assets-alt/images/x.png") "image\n";
  write_file (Filename.concat root "outside/secret.png") "secret\n";
  make_config ~root
    ~sources:["trees-md"]
    ~tree_roots:["generated"; "trees"]
    ~asset_roots:["assets"; "assets-alt"]
    ~output:"generated"

let with_symlink ~target ~link f =
  match Unix.symlink target link with
  | () -> f ()
  | exception Unix.Unix_error _ -> f ()

let expect_ok_scan name result =
  match result with
  | Ok t -> t
  | Error diagnostics ->
    let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
    Alcotest.fail (name ^ ": " ^ String.concat "; " messages)

let expect_code name code result =
  match result with
  | Ok _ -> Alcotest.fail (name ^ ": expected " ^ code)
  | Error diagnostics ->
    Alcotest.(check bool) (name ^ " reports " ^ code) true
      (List.exists (fun d -> Diagnostic.code_string d.Diagnostic.code = code)
         diagnostics)

let source_ids t =
  List.map (fun s -> s.Discovery.filename) t.Discovery.sources

let handwritten_ids t =
  List.map (fun h -> h.Discovery.id) t.Discovery.handwritten_roots

let test_scan_mirrors_and_orders () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    let t = expect_ok_scan "scan" (Discovery.scan config) in
    (* Sources are ordered by path now. The stem is only a search key, so
       ordering by it would imply it meant something. *)
    Alcotest.(check (list string)) "sources ordered by path"
      [ "foo"; "bar" ] (source_ids t);
    let find id =
      List.find (fun s -> s.Discovery.filename = id) t.Discovery.sources
    in
    let foo = find "foo" in
    let bar = find "bar" in
    Alcotest.(check string) "foo path"
      (Filename.concat root "trees-md/a/foo.tree.md") foo.Discovery.path;
    Alcotest.(check string) "foo source root"
      (Filename.concat root "trees-md") foo.Discovery.source_root;
    Alcotest.(check string) "foo config-relative"
      "trees-md/a/foo.tree.md" (Path_safe.to_string foo.config_relative);
    Alcotest.(check string) "foo source-relative"
      "a/foo.tree.md" (Path_safe.to_string foo.source_relative);
    Alcotest.(check string) "foo output-relative"
      "a/foo.tree" (Path_safe.to_string foo.output_relative);
    Alcotest.(check string) "bar path"
      (Filename.concat root "trees-md/b/bar.tree.md") bar.Discovery.path;
    Alcotest.(check string) "bar output-relative"
      "b/bar.tree" (Path_safe.to_string bar.output_relative);
    Alcotest.(check (list string)) "handwritten roots ordered" ["manual"]
      (handwritten_ids t);
    match t.Discovery.handwritten_roots with
    | [manual] ->
      Alcotest.(check string) "manual path"
        (Filename.concat root "trees/manual.tree") manual.Discovery.path
    | _ -> Alcotest.fail "expected exactly one handwritten root")

let test_symlinks_skipped () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    let link ~target ~name =
      with_symlink ~target ~link:(Filename.concat root name) (fun () -> ())
    in
    link ~target:"a/foo.tree.md" ~name:"trees-md/link-foo.tree.md";
    link ~target:"b" ~name:"trees-md/dirlink";
    link ~target:"manual.tree" ~name:"trees/link-manual.tree";
    link ~target:"../outside/secret.png" ~name:"assets/link.png";
    let t = expect_ok_scan "scan with symlinks" (Discovery.scan config) in
    Alcotest.(check (list string)) "symlink sources ignored"
      [ "foo"; "bar" ] (source_ids t);
    Alcotest.(check (list string)) "symlink handwritten ignored" ["manual"]
      (handwritten_ids t);
    Alcotest.(check (list string)) "symlinked asset not matched" []
      (Discovery.asset_matches config.forest (relative "link.png")))

let test_asset_matches () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    Alcotest.(check (list string)) "both asset roots match"
      [ Filename.concat root "assets/images/x.png";
        Filename.concat root "assets-alt/images/x.png" ]
      (Discovery.asset_matches config.forest (relative "images/x.png"));
    Alcotest.(check (list string)) "missing asset matches nothing" []
      (Discovery.asset_matches config.forest (relative "images/missing.png"));
    Alcotest.(check (list string)) "hidden component matches nothing" []
      (Discovery.asset_matches config.forest (relative ".hidden/x.png"));
    Alcotest.(check (list string)) "hidden filename matches nothing" []
      (Discovery.asset_matches config.forest (relative "images/.secret.png")))

let test_hidden_source_root_skipped () =
  with_fixture (fun root ->
    write_file (Filename.concat root "trees-md/a/foo.tree.md") "foo\n";
    write_file (Filename.concat root "trees-md/.hidden-root/inner.tree.md") "hidden\n";
    write_file (Filename.concat root "trees/manual.tree") "manual\n";
    let config = make_config ~root
      ~sources:["trees-md"]
      ~tree_roots:["generated"; "trees"]
      ~asset_roots:["assets"]
      ~output:"generated"
    in
    let t = expect_ok_scan "scan with hidden subroot" (Discovery.scan config) in
    Alcotest.(check (list string)) "hidden entries ignored" ["foo"]
      (source_ids t))

let test_nonexistent_generated_root_ok () =
  with_fixture (fun root ->
    write_file (Filename.concat root "trees-md/a/foo.tree.md") "foo\n";
    write_file (Filename.concat root "trees/manual.tree") "manual\n";
    let config = make_config ~root
      ~sources:["trees-md"]
      ~tree_roots:["generated"; "trees"]
      ~asset_roots:["assets"]
      ~output:"generated"
    in
    let t = expect_ok_scan "scan without generated directory" (Discovery.scan config) in
    Alcotest.(check (list string)) "generated root excluded" ["manual"]
      (handwritten_ids t))

(* Two folders may each hold a foo.tree.md. That is ordinary in a vault, and
   discovery no longer treats it as a collision: what may not be shared is an
   address, and Forest_index is where that is seen. *)
let test_duplicate_stems_accepted () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    write_file (Filename.concat root "trees-md/b/foo.tree.md") "duplicate foo\n";
    let t = expect_ok_scan "repeated stem" (Discovery.scan config) in
    Alcotest.(check (list string)) "both files discovered"
      [ "foo"; "bar"; "foo" ] (source_ids t))

let test_duplicate_handwritten_stems_error () =
  with_fixture (fun root ->
    write_file (Filename.concat root "trees-md/a/foo.tree.md") "foo\n";
    write_file (Filename.concat root "trees/manual.tree") "manual\n";
    write_file (Filename.concat root "trees2/manual.tree") "manual 2\n";
    let config = make_config ~root
      ~sources:["trees-md"]
      ~tree_roots:["generated"; "trees"; "trees2"]
      ~asset_roots:["assets"]
      ~output:"generated"
    in
    expect_code "duplicate handwritten stem" "TM201" (Discovery.scan config))

(* A source file name is a search key, so anything a file may be called is
   discovered: 日本語のノート, "My Note". A handwritten .tree is different —
   Forester reads its address straight off the file name — so that one is
   still required to be an address. *)
let test_nonaddress_source_stems_accepted () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    write_file (Filename.concat root "trees-md/My Note.tree.md") "spaced\n";
    write_file (Filename.concat root "trees-md/日本語のノート.tree.md") "japanese\n";
    let t = expect_ok_scan "non-address stems" (Discovery.scan config) in
    Alcotest.(check bool) "spaced file discovered" true
      (List.mem "My Note" (source_ids t));
    Alcotest.(check bool) "japanese file discovered" true
      (List.mem "日本語のノート" (source_ids t)))

let test_invalid_handwritten_stem_error () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    write_file (Filename.concat root "trees/bad tree.tree") "bad handwritten\n";
    expect_code "handwritten stem must be an address" "TM201"
      (Discovery.scan config))

let test_type_change_error () =
  with_fixture (fun root ->
    let config = standard_fixture ~root in
    write_file (Filename.concat root "trees-md/changed.tree.md/inner.tree.md")
      "inside directory\n";
    match Discovery.scan config with
    | Ok _ -> Alcotest.fail "directory claiming .tree.md suffix accepted"
    | Error diagnostics ->
      let tm205 =
        List.find (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM205")
          diagnostics
      in
      Alcotest.(check bool) "type-change message names path" true
        (contains tm205.Diagnostic.message "changed.tree.md"))

let test_missing_source_root_error () =
  with_fixture (fun root ->
    write_file (Filename.concat root "trees-md/a/foo.tree.md") "foo\n";
    write_file (Filename.concat root "trees/manual.tree") "manual\n";
    let config = make_config ~root
      ~sources:["trees-md"; "missing-root"]
      ~tree_roots:["generated"; "trees"]
      ~asset_roots:["assets"]
      ~output:"generated"
    in
    expect_code "missing source root" "TM404" (Discovery.scan config))

let test_symlinked_source_root_error () =
  with_fixture (fun root ->
    write_file (Filename.concat root "real/inner.tree.md") "inner\n";
    let link = Filename.concat root "linked-root" in
    with_symlink ~target:"real" ~link (fun () ->
      let config = make_config ~root
        ~sources:["linked-root"]
        ~tree_roots:["generated"]
        ~asset_roots:["assets"]
        ~output:"generated"
      in
      expect_code "symlinked source root" "TM404" (Discovery.scan config)))

let () =
  let open Alcotest in
  run "Discovery"
    [ "scan", [
        test_case "discovers_and_mirrors" `Quick test_scan_mirrors_and_orders;
        test_case "symlinks_skipped" `Quick test_symlinks_skipped;
        test_case "asset_matches" `Quick test_asset_matches;
        test_case "hidden_source_root_skipped" `Quick test_hidden_source_root_skipped;
        test_case "nonexistent_generated_root_ok" `Quick test_nonexistent_generated_root_ok;
      ]
    ; "errors", [
        test_case "duplicate_stems_accepted" `Quick test_duplicate_stems_accepted;
        test_case "duplicate_handwritten_stems" `Quick test_duplicate_handwritten_stems_error;
        test_case "nonaddress_source_stems_accepted" `Quick
          test_nonaddress_source_stems_accepted;
        test_case "invalid_handwritten_stem" `Quick
          test_invalid_handwritten_stem_error;
        test_case "type_change" `Quick test_type_change_error;
        test_case "missing_source_root" `Quick test_missing_source_root_error;
        test_case "symlinked_source_root" `Quick test_symlinked_source_root_error;
      ]
    ]
