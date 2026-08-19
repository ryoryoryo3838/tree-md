open Tree_md

(* Each compile stage now returns its warnings alongside the value it
   produced. These suites assert on the value, so they drop the warnings. *)
let compile_forest config discovery =
  Result.map
    (fun (forest, _warnings) -> forest.Compiler.outputs)
    (Compiler.compile_forest config discovery)

let contains haystack needle =
  let needle_length = String.length needle in
  let rec loop i =
    i + needle_length <= String.length haystack
    && (String.sub haystack i needle_length = needle || loop (i + 1))
  in
  loop 0

let sha256_hex bytes =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)

let is_lowercase_hex_64 value =
  String.length value = 64
  && String.for_all (fun c ->
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) value

let relative value =
  match Path_safe.relative value with
  | Ok relative -> relative
  | Error message -> Alcotest.fail (value ^ ": " ^ message)

let resolve base path = Path_safe.resolve ~base (relative path)

let resolve_fixture_path relative =
  let sandbox_path = Filename.concat "fixtures" relative in
  if Sys.file_exists sandbox_path then sandbox_path
  else
    let executable_directory = Filename.dirname (Unix.realpath Sys.executable_name) in
    let build_root =
      executable_directory
      |> Filename.dirname |> Filename.dirname |> Filename.dirname
      |> Filename.dirname |> Filename.dirname
    in
    Filename.concat build_root ("test/fixtures/" ^ relative)

let render_diagnostics name diagnostics =
  let messages =
    List.map (fun d ->
      Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code)
        d.Diagnostic.message)
      diagnostics
    |> String.concat "; "
  in
  name ^ ": " ^ messages

let load_and_scan workspace =
  let config_path = resolve_fixture_path (workspace ^ "/tree-md.toml") in
  match Config.load ~path:config_path with
  | Error diagnostics ->
    Alcotest.fail (render_diagnostics "config load failed" diagnostics)
  | Ok config ->
    (match Discovery.scan config with
     | Error diagnostics ->
       Alcotest.fail (render_diagnostics "discovery failed" diagnostics)
     | Ok discovery -> (config, discovery))

let check_record (record : Compiler.expected) ~source ~source_config_relative
    ~output_relative ~bytes =
  Alcotest.(check string) "source path" source record.source_path;
  Alcotest.(check string) "config-relative source" source_config_relative
    (Path_safe.to_string record.source_config_relative);
  Alcotest.(check string) "output-relative" output_relative
    (Path_safe.to_string record.output_relative);
  Alcotest.(check string) "exact bytes" bytes record.bytes;
  Alcotest.(check string) "sha256 hashes exact bytes"
    (sha256_hex bytes) record.sha256;
  Alcotest.(check bool) "sha256 is 64 lowercase hex digits" true
    (is_lowercase_hex_64 record.sha256)

let test_multi_document_forest () =
  let config, discovery = load_and_scan "workspaces/compile" in
  match compile_forest config discovery with
  | Error diagnostics ->
    Alcotest.fail (render_diagnostics "multi-document forest rejected" diagnostics)
  | Ok expecteds ->
    Alcotest.(check int) "one expected record per source" 2
      (List.length expecteds);
    (match expecteds with
     | [ first; second ] ->
       Alcotest.(check string) "records sorted by output path" "child.tree"
         (Path_safe.to_string first.output_relative);
       Alcotest.(check string) "second output path" "index.tree"
         (Path_safe.to_string second.output_relative);
       check_record first
         ~source:(Filename.concat config.Config.directory "trees-md/child.tree.md")
         ~source_config_relative:"trees-md/child.tree.md"
         ~output_relative:"child.tree"
         ~bytes:"\\title{Child}\n\\p{Child body text.}\n";
       check_record second
         ~source:(Filename.concat config.Config.directory "trees-md/index.tree.md")
         ~source_config_relative:"trees-md/index.tree.md"
         ~output_relative:"index.tree"
         ~bytes:
            "\\title{Index}\n\\date{2026-08-04}\n\\author{manual}\n\n\
             \\p{Link to [[child]].}\n\n\
             \\transclude{child}\n\n\
             \\p{\\<html:img>[src]{\\route-asset{assets/images/x.png}}[alt]{Plot}{}}\n";
       Alcotest.(check bool) "routed asset path emitted" true
         (contains second.bytes "\\route-asset{assets/images/x.png}");
       (* determinism: byte-identical output across two calls *)
       (match compile_forest config discovery with
        | Error diagnostics ->
          Alcotest.fail (render_diagnostics "second compile rejected" diagnostics)
        | Ok again ->
          let project (e : Compiler.expected) =
            (Path_safe.to_string e.output_relative, e.bytes, e.sha256)
          in
          Alcotest.(check (list (triple string string string)))
            "byte-identical across calls"
            (List.map project expecteds) (List.map project again))
     | _ -> Alcotest.fail "expected exactly two expected records")

let test_bad_forest_diagnostics () =
  let config, discovery = load_and_scan "workspaces/compile-bad" in
  match compile_forest config discovery with
  | Ok _ -> Alcotest.fail "bad forest compiled without diagnostics"
  | Error diagnostics ->
    Alcotest.(check (list string))
      "all independent diagnostics in deterministic order"
      [ "TM202"; "TM204"; "TM203"; "TM102" ]
      (List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics);
    let message_of code =
      match
        List.find_opt
          (fun d -> Diagnostic.code_string d.Diagnostic.code = code)
          diagnostics
      with
      | Some d -> d.Diagnostic.message
      | None -> Alcotest.fail ("no " ^ code ^ " diagnostic")
    in
    Alcotest.(check bool) "TM202 names unresolved target" true
      (contains (message_of "TM202") "missing");
    Alcotest.(check bool) "TM204 names ambiguous asset" true
      (contains (message_of "TM204") "images/shared.png");
    Alcotest.(check bool) "TM203 names missing asset" true
      (contains (message_of "TM203") "images/absent.png");
    Alcotest.(check bool) "TM102 names raw block HTML" true
      (contains (message_of "TM102") "raw block HTML")

let make_config ~root =
  ({ Config.path = Filename.concat root "tree-md.toml";
     directory = root;
     forest = {
       Config.path = Filename.concat root "forest.toml";
       directory = root;
       tree_roots =
         [ (relative "generated", resolve root "generated");
           (relative "trees", resolve root "trees") ];
       asset_roots = [ (relative "assets", resolve root "assets") ];
     };
     source_roots = [ (relative "trees-md", resolve root "trees-md") ];
     output_root = (relative "generated", resolve root "generated");
     target = Forester_6.target;
     publish_from = []; id = Config.default_id_policy }
    : Config.t)

let with_temp_dir f =
  let root = Filename.temp_file "tree-md-compile-" ".dir" in
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
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let test_symlinked_source_rejected () =
  with_temp_dir (fun root ->
    let real = Filename.concat root "real.tree.md" in
    let link = Filename.concat root "linked.tree.md" in
    let channel = open_out_bin real in
    output_string channel "# Real\n";
    close_out channel;
    Unix.symlink real link;
    let config = make_config ~root in
    let discovery =
      { Discovery.sources =
          [ { Discovery.source_root = root;
              path = link;
              config_relative = relative "linked.tree.md";
              source_relative = relative "linked.tree.md";
              output_relative = relative "linked.tree";
              filename = "linked" } ];
        handwritten_roots = [] }
    in
    match compile_forest config discovery with
    | Ok _ -> Alcotest.fail "symlinked source compiled"
    | Error diagnostics ->
      Alcotest.(check (list string)) "TM404 for symlinked source"
        [ "TM404" ]
        (List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics))

(* A UTF-8 BOM is well-formed UTF-8, so it passes the TM001 encoding check.
   Left alone it silently corrupts the output: the leading "# Title" is no
   longer an ATX heading, so the root title falls back to the filename stem
   and the heading text leaks into the body carrying the BOM bytes. It must
   be a TM003 source error, not a successful compile. *)
let test_bom_rejected () =
  with_temp_dir (fun root ->
    let source = Filename.concat root "bom.tree.md" in
    let channel = open_out_bin source in
    output_string channel "\xef\xbb\xbf# BOM Title\n\nBody.\n";
    close_out channel;
    let config = make_config ~root in
    let discovery =
      { Discovery.sources =
          [ { Discovery.source_root = root;
              path = source;
              config_relative = relative "bom.tree.md";
              source_relative = relative "bom.tree.md";
              output_relative = relative "bom.tree";
              filename = "bom" } ];
        handwritten_roots = [] }
    in
    match compile_forest config discovery with
    | Ok _ -> Alcotest.fail "source with a UTF-8 BOM compiled"
    | Error diagnostics ->
      Alcotest.(check (list string)) "TM003 for leading BOM"
        [ "TM003" ]
        (List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics))

(* The same bytes without the BOM are a perfectly ordinary document, so the
   check above must be rejecting the BOM and nothing else. *)
let test_no_bom_still_compiles () =
  with_temp_dir (fun root ->
    let source = Filename.concat root "plain.tree.md" in
    let channel = open_out_bin source in
    output_string channel "# BOM Title\n\nBody.\n";
    close_out channel;
    let config = make_config ~root in
    let discovery =
      { Discovery.sources =
          [ { Discovery.source_root = root;
              path = source;
              config_relative = relative "plain.tree.md";
              source_relative = relative "plain.tree.md";
              output_relative = relative "plain.tree";
              filename = "plain" } ];
        handwritten_roots = [] }
    in
    match compile_forest config discovery with
    | Error diagnostics ->
      Alcotest.fail (render_diagnostics "BOM-free source rejected" diagnostics)
    | Ok [ record ] ->
      Alcotest.(check string) "H1 becomes the root title"
        "\\title{BOM Title}\n\\p{Body.}\n" record.Compiler.bytes
    | Ok _ -> Alcotest.fail "expected exactly one compiled record")

(* A file name that could not be a Forester address leaves the tree without
   one. That is TM206 wherever nothing is going to mint one — `check`, and a
   build with mint = "off" — and tolerated only by the compile that runs just
   before minting, which is about to fix it. *)
let unaddressed_discovery root ~stem =
  let source = Filename.concat root (stem ^ ".tree.md") in
  let channel = open_out_bin source in
  output_string channel "# 見出し\n\n本文。\n";
  close_out channel;
  { Discovery.sources =
      [ { Discovery.source_root = root;
          path = source;
          config_relative = relative (stem ^ ".tree.md");
          source_relative = relative (stem ^ ".tree.md");
          output_relative = relative (stem ^ ".tree");
          filename = stem } ];
    handwritten_roots = [] }

let test_unaddressed_tree_tm206 () =
  with_temp_dir (fun root ->
    let config = make_config ~root in
    let discovery = unaddressed_discovery root ~stem:"日本語のノート" in
    match compile_forest config discovery with
    | Ok _ -> Alcotest.fail "tree with no possible address compiled"
    | Error diagnostics ->
      Alcotest.(check (list string)) "TM206 for an unaddressed tree"
        [ "TM206" ]
        (List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) diagnostics);
      Alcotest.(check bool) "message names the file" true
        (contains (List.hd diagnostics).Diagnostic.message "日本語のノート"))

let test_unaddressed_tree_allowed_before_minting () =
  with_temp_dir (fun root ->
    let config = make_config ~root in
    let discovery = unaddressed_discovery root ~stem:"日本語のノート" in
    match
      Result.map fst
        (Compiler.compile_forest ~allow_pending:true config discovery)
    with
    | Error diagnostics ->
      Alcotest.fail (render_diagnostics "pre-mint compile rejected" diagnostics)
    | Ok forest ->
      Alcotest.(check int) "the forest still compiles" 1
        (List.length forest.Compiler.outputs))

(* ── [publish].from: a vault as the source, without the vault as the site ── *)

let source_record root relative_path =
  let path = Filename.concat root relative_path in
  { Discovery.source_root = Filename.concat root "trees-md";
    path;
    config_relative = relative relative_path;
    source_relative =
      relative
        (String.sub relative_path (String.length "trees-md/")
           (String.length relative_path - String.length "trees-md/"));
    output_relative =
      relative
        (let inner =
           String.sub relative_path (String.length "trees-md/")
             (String.length relative_path - String.length "trees-md/")
         in
         String.sub inner 0 (String.length inner - String.length ".tree.md")
         ^ ".tree");
    filename =
      (let base = Filename.basename relative_path in
       String.sub base 0 (String.length base - String.length ".tree.md")) }

let write_source root relative_path contents =
  let path = Filename.concat root relative_path in
  let rec mkdirs dir =
    if not (Sys.file_exists dir) then begin
      mkdirs (Filename.dirname dir);
      try Unix.mkdir dir 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdirs (Filename.dirname path);
  let channel = open_out_bin path in
  output_string channel contents;
  close_out channel

let publish_fixture root =
  write_source root "trees-md/PUBLIC/index.tree.md"
    "---\nid: index\n---\n\n# Home\n\n[[notes]]\n";
  write_source root "trees-md/PUBLIC/notes.tree.md"
    "---\nid: notes\n---\n\n# Notes\n\n![[frege.tree]]\n";
  write_source root "trees-md/private/frege.tree.md"
    "---\nid: frege\n---\n\n# Frege\n";
  (* Nobody publishes this, and it is broken: a build that carries the site
     must not fail because of a draft it does not carry. *)
  write_source root "trees-md/DAILY/2026-08-19.tree.md"
    "---\nid: diary\n---\n\n# Diary\n\n[[nothing-at-all]]\n";
  { Discovery.sources =
      [ source_record root "trees-md/PUBLIC/index.tree.md";
        source_record root "trees-md/PUBLIC/notes.tree.md";
        source_record root "trees-md/private/frege.tree.md";
        source_record root "trees-md/DAILY/2026-08-19.tree.md" ];
    handwritten_roots = [] }

let publishing_config ~root from =
  let base = make_config ~root in
  { base with Config.publish_from = from }

let test_publish_from_selects_and_reaches () =
  with_temp_dir (fun root ->
    let discovery = publish_fixture root in
    let config = publishing_config ~root [ "PUBLIC/**" ] in
    match Compiler.compile_forest config discovery with
    | Error diagnostics ->
      Alcotest.fail (render_diagnostics "a selective build failed" diagnostics)
    | Ok (forest, _warnings) ->
      Alcotest.(check (list string)) "the entries and what they reach"
        [ "PUBLIC/index.tree"; "PUBLIC/notes.tree"; "private/frege.tree" ]
        (List.map
           (fun (e : Compiler.expected) -> Path_safe.to_string e.Compiler.output_relative)
           forest.Compiler.outputs
         |> List.sort String.compare);
      Alcotest.(check int) "the draft is counted, not compiled" 1
        forest.Compiler.unpublished)

(* The whole point: a note nobody publishes is not compiled, so its broken
   link does not fail the build for the pages that are. *)
let test_unpublished_diagnostics_are_dropped () =
  with_temp_dir (fun root ->
    let discovery = publish_fixture root in
    let all = make_config ~root in
    (match Compiler.compile_forest all discovery with
     | Ok _ -> Alcotest.fail "the broken draft compiled when everything is published"
     | Error diagnostics ->
       Alcotest.(check bool) "TM202 without [publish]" true
         (List.exists
            (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM202")
            diagnostics));
    let selective = publishing_config ~root [ "PUBLIC/**" ] in
    match Compiler.compile_forest selective discovery with
    | Error diagnostics ->
      Alcotest.fail (render_diagnostics "the draft still failed the build" diagnostics)
    | Ok _ -> ())

(* An entry that does not parse is still the writer's business: it was put in a
   published folder. *)
let test_published_entry_still_reports () =
  with_temp_dir (fun root ->
    let discovery = publish_fixture root in
    write_source root "trees-md/PUBLIC/broken.tree.md"
      "---\nid: broken\n---\n\n<div>raw block html</div>\n";
    let discovery =
      { discovery with
        Discovery.sources =
          discovery.Discovery.sources
          @ [ source_record root "trees-md/PUBLIC/broken.tree.md" ] }
    in
    let config = publishing_config ~root [ "PUBLIC/**" ] in
    match Compiler.compile_forest config discovery with
    | Ok _ -> Alcotest.fail "a broken published entry compiled"
    | Error diagnostics ->
      Alcotest.(check bool) "TM102 from the published entry" true
        (List.exists
           (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM102")
           diagnostics))

(* Two trees may share an address without either being an entry. Reachability
   pulls in every owner of the address a reference lands on, so the collision
   is reported rather than silently decided by which path sorts first. *)
let test_duplicate_identity_is_not_silently_picked () =
  with_temp_dir (fun root ->
    write_source root "trees-md/PUBLIC/index.tree.md"
      "---\nid: index\n---\n\n# Home\n\n[[frege]]\n";
    write_source root "trees-md/private/frege.tree.md"
      "---\nid: shared\n---\n\n# Frege\n";
    write_source root "trees-md/private/other.tree.md"
      "---\nid: other\n---\n\n## Also ^shared\n\nBody.\n";
    let discovery =
      { Discovery.sources =
          [ source_record root "trees-md/PUBLIC/index.tree.md";
            source_record root "trees-md/private/frege.tree.md";
            source_record root "trees-md/private/other.tree.md" ];
        handwritten_roots = [] }
    in
    let config = publishing_config ~root [ "PUBLIC/**" ] in
    match Compiler.compile_forest config discovery with
    | Ok _ -> Alcotest.fail "a shared address was picked between in silence"
    | Error diagnostics ->
      Alcotest.(check bool) "TM201 names the collision" true
        (List.exists
           (fun d ->
             Diagnostic.code_string d.Diagnostic.code = "TM201"
             && contains d.Diagnostic.message "shared")
           diagnostics))

let () =
  let open Alcotest in
  run "Forest_compile"
    [ "forests", [
        test_case "multi_document_forest" `Quick test_multi_document_forest;
        test_case "bad_forest_diagnostics" `Quick test_bad_forest_diagnostics;
        test_case "symlinked_source_rejected" `Quick test_symlinked_source_rejected;
        test_case "bom_rejected" `Quick test_bom_rejected;
        test_case "no_bom_still_compiles" `Quick test_no_bom_still_compiles;
        test_case "unaddressed_tree_tm206" `Quick test_unaddressed_tree_tm206;
        test_case "publish_from_selects_and_reaches" `Quick
          test_publish_from_selects_and_reaches;
        test_case "unpublished_diagnostics_are_dropped" `Quick
          test_unpublished_diagnostics_are_dropped;
        test_case "published_entry_still_reports" `Quick
          test_published_entry_still_reports;
        test_case "duplicate_identity_is_not_silently_picked" `Quick
          test_duplicate_identity_is_not_silently_picked;
        test_case "unaddressed_tree_allowed_before_minting" `Quick
          test_unaddressed_tree_allowed_before_minting;
      ]
    ]
