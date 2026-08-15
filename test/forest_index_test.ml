open Tree_md

let relative value =
  match Path_safe.relative value with
  | Ok relative -> relative
  | Error message -> Alcotest.fail (value ^ ": " ^ message)

let resolve base path = Path_safe.resolve ~base (relative path)

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

let with_fixture f =
  let root = Filename.temp_file "tree-md-index-" ".dir" in
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

let with_symlink ~target ~link f =
  match Unix.symlink target link with
  | () -> f ()
  | exception Unix.Unix_error _ -> f ()

let parse_doc ~root_id ~path text =
  match Source.of_string ~path text with
  | Ok source ->
    (match Compiler.parse ~root_id source with
     | Ok doc -> doc
     | Error diagnostics ->
       let messages =
         List.map (fun d -> d.Diagnostic.message) diagnostics
         |> String.concat "; "
       in
       Alcotest.fail ("parse failed for " ^ path ^ ": " ^ messages))
  | Error _ -> Alcotest.fail ("invalid UTF-8 in " ^ path)

let make_forest ~root ~asset_roots =
  let pairs names =
    List.map (fun name -> (relative name, resolve root name)) names
  in
  ({ Config.path = Filename.concat root "forest.toml";
     directory = root;
     tree_roots = pairs ["generated"];
     asset_roots = pairs asset_roots } : Config.forest)

let expect_build name ~handwritten ~generated =
  match Forest_index.build ~handwritten ~generated with
  | Ok index -> index
  | Error diagnostics ->
    let messages =
      List.map (fun d ->
        Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code)
          d.Diagnostic.message)
        diagnostics
      |> String.concat "; "
    in
    Alcotest.fail (name ^ ": " ^ messages)

let expect_code name code result =
  match result with
  | Ok _ -> Alcotest.fail (name ^ ": expected " ^ code)
  | Error diagnostics ->
    Alcotest.(check bool) (name ^ " reports " ^ code) true
      (List.exists
         (fun d -> Diagnostic.code_string d.Diagnostic.code = code)
         diagnostics)

let span_path = function
  | Span.Source_span s -> s.Span.path
  | Span.Path path -> path
  | Span.No_location -> "<no location>"

let span_byte = function
  | Span.Source_span s -> Some s.Span.start_byte
  | Span.Path _ | Span.No_location -> None

let primary_of code diagnostics =
  match List.find_opt (fun d -> Diagnostic.code_string d.Diagnostic.code = code)
          diagnostics with
  | Some d -> d
  | None ->
    Alcotest.fail ("no " ^ code ^ " diagnostic; got "
                   ^ String.concat ";"
                       (List.map
                          (fun d -> Diagnostic.code_string d.Diagnostic.code)
                          diagnostics))

(* ── build: duplicate identity diagnostics ── *)

let test_duplicate_generated_roots () =
  with_fixture (fun root ->
    let first = Filename.concat root "trees-md/a-first.tree.md" in
    let later = Filename.concat root "trees-md/b-later.tree.md" in
    let first_doc = parse_doc ~root_id:"dup" ~path:first "# Alpha\n" in
    let later_doc = parse_doc ~root_id:"dup" ~path:later "# Beta\n" in
    match
      Forest_index.build ~handwritten:[] ~generated:[ first_doc; later_doc ]
    with
    | Ok _ -> Alcotest.fail "duplicate generated roots accepted"
    | Error diagnostics ->
      let diag = primary_of "TM201" diagnostics in
      Alcotest.(check bool) "first definition is primary" true
        (diag.Diagnostic.primary = Span.Source_span
           first_doc.Parsed_document.outline.Outline.span);
      Alcotest.(check int) "every later definition labelled" 1
        (List.length diag.Diagnostic.secondary);
      (match diag.Diagnostic.secondary with
       | [ { Diagnostic.label; location } ] ->
         Alcotest.(check string) "secondary label" "also defined here" label;
         Alcotest.(check bool) "secondary is later definition" true
           (location = Span.Source_span
              later_doc.Parsed_document.outline.Outline.span)
       | _ -> Alcotest.fail "expected one secondary location");
      Alcotest.(check int) "diagnostics sorted by path" 1
        (List.length diagnostics))

let test_duplicate_subtree_orders_by_byte () =
  with_fixture (fun root ->
    let path = Filename.concat root "trees-md/one.tree.md" in
    let text =
      "# One\n\n<!-- subtree: sec -->\n## First\n\n\
       <!-- subtree: sec -->\n## Second\n"
    in
    let doc = parse_doc ~root_id:"one" ~path text in
    match Forest_index.build ~handwritten:[] ~generated:[ doc ] with
    | Ok _ -> Alcotest.fail "duplicate subtree identities accepted"
    | Error diagnostics ->
      let diag = primary_of "TM201" diagnostics in
      let primary_byte = span_byte diag.Diagnostic.primary in
      (match diag.Diagnostic.secondary with
       | [ { Diagnostic.location; _ } ] ->
         Alcotest.(check bool) "same source path" true
           (span_path diag.Diagnostic.primary = span_path location);
         (match primary_byte, span_byte location with
          | Some first, Some later ->
            Alcotest.(check bool) "first definition by byte is primary" true
              (first < later)
          | _ -> Alcotest.fail "expected byte locations")
       | _ -> Alcotest.fail "expected one secondary location"))

let test_root_versus_named_subtree () =
  with_fixture (fun root ->
    let root_path = Filename.concat root "trees-md/a-root.tree.md" in
    let subtree_path = Filename.concat root "trees-md/b-sub.tree.md" in
    let root_doc = parse_doc ~root_id:"shared" ~path:root_path "# Shared\n" in
    let subtree_doc =
      parse_doc ~root_id:"other" ~path:subtree_path
        "# Other\n\n<!-- subtree: shared -->\n## S\n"
    in
    match
      Forest_index.build ~handwritten:[]
        ~generated:[ root_doc; subtree_doc ]
    with
    | Ok _ -> Alcotest.fail "root/subtree identity collision accepted"
    | Error diagnostics ->
      let diag = primary_of "TM201" diagnostics in
      Alcotest.(check string) "primary is the generated root path"
        root_path (span_path diag.Diagnostic.primary);
      (match diag.Diagnostic.secondary with
       | [ { Diagnostic.location; _ } ] ->
         Alcotest.(check string) "secondary is the named subtree path"
           subtree_path (span_path location)
       | _ -> Alcotest.fail "expected one secondary location"))

let test_two_named_subtrees () =
  with_fixture (fun root ->
    let first = Filename.concat root "trees-md/a-first.tree.md" in
    let second = Filename.concat root "trees-md/b-second.tree.md" in
    let first_doc =
      parse_doc ~root_id:"first" ~path:first
        "# First\n\n<!-- subtree: sec -->\n## S\n"
    in
    let second_doc =
      parse_doc ~root_id:"second" ~path:second
        "# Second\n\n<!-- subtree: sec -->\n## S\n"
    in
    match
      Forest_index.build ~handwritten:[]
        ~generated:[ first_doc; second_doc ]
    with
    | Ok _ -> Alcotest.fail "cross-document subtree collision accepted"
    | Error diagnostics ->
      let diag = primary_of "TM201" diagnostics in
      Alcotest.(check string) "primary is first source path"
        first (span_path diag.Diagnostic.primary);
      Alcotest.(check int) "one labelled later definition" 1
        (List.length diag.Diagnostic.secondary))

let test_generated_versus_handwritten_root () =
  with_fixture (fun root ->
    let generated_path = Filename.concat root "trees-md/g-manual.tree.md" in
    let handwritten_path = Filename.concat root "trees/manual.tree" in
    let generated_doc =
      parse_doc ~root_id:"manual" ~path:generated_path "# Manual\n"
    in
    let handwritten =
      [ { Discovery.id = "manual"; path = handwritten_path } ]
    in
    match Forest_index.build ~handwritten ~generated:[ generated_doc ] with
    | Ok _ -> Alcotest.fail "generated/handwritten collision accepted"
    | Error diagnostics ->
      let diag = primary_of "TM201" diagnostics in
      Alcotest.(check string) "primary is generated root path"
        generated_path (span_path diag.Diagnostic.primary);
      (match diag.Diagnostic.secondary with
       | [ { Diagnostic.location = Span.Path path; _ } ] ->
         Alcotest.(check string) "secondary names handwritten path"
           handwritten_path path
       | _ -> Alcotest.fail "expected one Path secondary location"))

let test_clean_forest_builds () =
  with_fixture (fun root ->
    let alpha = Filename.concat root "trees-md/alpha.tree.md" in
    let beta = Filename.concat root "trees-md/beta.tree.md" in
    let alpha_doc =
      parse_doc ~root_id:"alpha" ~path:alpha
        "# Alpha\n\n<!-- subtree: sec -->\n## S\n"
    in
    let beta_doc = parse_doc ~root_id:"beta" ~path:beta "# Beta\n" in
    let handwritten =
      [ { Discovery.id = "manual"; path = Filename.concat root "trees/manual.tree" } ]
    in
    expect_build "clean forest" ~handwritten
      ~generated:[ alpha_doc; beta_doc ]
    |> ignore)

(* ── references: TM202 for unresolved wiki/embed/attribution ── *)

let test_unresolved_wiki_link () =
  with_fixture (fun root ->
    let path = Filename.concat root "trees-md/a.tree.md" in
    let doc = parse_doc ~root_id:"a" ~path:path "# A\n\n[[missing]]\n" in
    let index = expect_build "wiki index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents:[ doc ] with
    | Ok _ -> Alcotest.fail "unresolved wiki link accepted"
    | Error diagnostics ->
      let diag = primary_of "TM202" diagnostics in
      Alcotest.(check bool) "message names target" true
        (contains diag.Diagnostic.message "missing");
      Alcotest.(check bool) "diagnostic at source span" true
        (diag.Diagnostic.primary = Span.Source_span
           (List.hd doc.Parsed_document.references).Ir.span))

let test_unresolved_embed () =
  with_fixture (fun root ->
    let path = Filename.concat root "trees-md/a.tree.md" in
    let doc =
      parse_doc ~root_id:"a" ~path:path "# A\n\n![[missing-embed]]\n"
    in
    let index = expect_build "embed index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents:[ doc ] with
    | Ok _ -> Alcotest.fail "unresolved embed accepted"
    | Error diagnostics ->
      let diag = primary_of "TM202" diagnostics in
      Alcotest.(check bool) "message names embed target" true
        (contains diag.Diagnostic.message "missing-embed"))

let test_unresolved_attributions () =
  with_fixture (fun root ->
    let path = Filename.concat root "trees-md/a.tree.md" in
    let text =
      "---\n" ^
      "authors: [\"[[missing-author]]\", \"Ada Lovelace\"]\n" ^
      "contributors: [\"[[missing-contrib]]\"]\n" ^
      "---\n# A\n"
    in
    let doc = parse_doc ~root_id:"a" ~path:path text in
    let index = expect_build "attribution index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents:[ doc ] with
    | Ok _ -> Alcotest.fail "unresolved attributions accepted"
    | Error diagnostics ->
      let tm202 =
        List.filter (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM202")
          diagnostics
      in
      Alcotest.(check int) "exactly two unresolved attributions" 2
        (List.length tm202);
      Alcotest.(check bool) "author target named" true
        (List.exists (fun d -> contains d.Diagnostic.message "missing-author")
           tm202);
      Alcotest.(check bool) "contributor target named" true
        (List.exists (fun d -> contains d.Diagnostic.message "missing-contrib")
           tm202))

let test_literal_attribution_and_plain_link_ignored () =
  with_fixture (fun root ->
    let path = Filename.concat root "trees-md/a.tree.md" in
    let text =
      "---\n" ^
      "authors: [\"Ada Lovelace\"]\n" ^
      "---\n# A\n\n[visit](notes/other.md)\n"
    in
    let doc = parse_doc ~root_id:"a" ~path:path text in
    let index = expect_build "literal index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents:[ doc ] with
    | Ok results ->
      Alcotest.(check (list string)) "one per-document resolution"
        [ "a" ] (List.map fst results)
    | Error diagnostics ->
      let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
      Alcotest.fail ("literal attribution or plain link rejected: "
                     ^ String.concat "; " messages))

(* ── assets: TM203 / TM204 / TM205 and routed paths ── *)

let image_doc ~root ~destination =
  let path = Filename.concat root "trees-md/a.tree.md" in
  parse_doc ~root_id:"a" ~path:path
    ("# A\n\n![Plot](" ^ destination ^ ")\n")

let asset_span doc =
  match doc.Parsed_document.local_assets with
  | [ asset ] -> asset.Parsed_document.span
  | _ -> Alcotest.fail "expected exactly one local asset"

let test_asset_zero_matches () =
  with_fixture (fun root ->
    let doc = image_doc ~root ~destination:"images/missing.png" in
    let index = expect_build "missing asset index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    expect_code "zero asset matches" "TM203"
      (Forest_index.resolve forest index ~documents:[ doc ]))

let test_asset_ambiguous_two_roots () =
  with_fixture (fun root ->
    write_file (Filename.concat root "assets/images/x.png") "image\n";
    write_file (Filename.concat root "assets-alt/images/x.png") "image\n";
    let doc = image_doc ~root ~destination:"images/x.png" in
    let index = expect_build "ambiguous index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:[ "assets"; "assets-alt" ] in
    match Forest_index.resolve forest index ~documents:[ doc ] with
    | Ok _ -> Alcotest.fail "ambiguous asset accepted"
    | Error diagnostics ->
      let diag = primary_of "TM204" diagnostics in
      Alcotest.(check bool) "message names destination" true
        (contains diag.Diagnostic.message "images/x.png"))

let test_asset_single_match_routes () =
  with_fixture (fun root ->
    write_file (Filename.concat root "assets/images/x.png") "image\n";
    let doc = image_doc ~root ~destination:"images/x.png" in
    let index = expect_build "routed index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents:[ doc ] with
    | Ok results ->
      (match results with
       | [ (root_id, resolution) ] ->
         Alcotest.(check string) "keyed by outline root id" "a" root_id;
         Alcotest.(check (option string)) "exact forest-relative routed path"
           (Some "assets/images/x.png")
           (Resolution.asset_route resolution (asset_span doc))
       | _ -> Alcotest.fail "expected one per-document resolution")
    | Error diagnostics ->
      let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
      Alcotest.fail ("single match not routed: " ^ String.concat "; " messages))

let test_asset_symlink_file_escape () =
  with_fixture (fun root ->
    write_file (Filename.concat root "outside/secret.png") "secret\n";
    write_file (Filename.concat root "assets/images/keep.png") "keep\n";
    let link = Filename.concat root "assets/images/x.png" in
    with_symlink ~target:"../../outside/secret.png" ~link (fun () ->
      let doc = image_doc ~root ~destination:"images/x.png" in
      let index = expect_build "symlink index" ~handwritten:[] ~generated:[ doc ] in
      let forest = make_forest ~root ~asset_roots:["assets"] in
      match Forest_index.resolve forest index ~documents:[ doc ] with
      | Ok _ -> Alcotest.fail "symlinked asset accepted"
      | Error diagnostics ->
        let diag = primary_of "TM205" diagnostics in
        Alcotest.(check bool) "message names destination" true
          (contains diag.Diagnostic.message "images/x.png")))

let test_asset_symlinked_directory_escape () =
  with_fixture (fun root ->
    write_file (Filename.concat root "outside/x.png") "secret\n";
    write_file (Filename.concat root "assets/keep.png") "keep\n";
    let link = Filename.concat root "assets/images" in
    with_symlink ~target:"../outside" ~link (fun () ->
      let doc = image_doc ~root ~destination:"images/x.png" in
      let index = expect_build "dir symlink index" ~handwritten:[] ~generated:[ doc ] in
      let forest = make_forest ~root ~asset_roots:["assets"] in
      expect_code "symlinked directory escape" "TM205"
        (Forest_index.resolve forest index ~documents:[ doc ])))

let test_asset_hidden_destination () =
  with_fixture (fun root ->
    let doc = image_doc ~root ~destination:".hidden/x.png" in
    let index = expect_build "hidden index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    expect_code "hidden destination" "TM205"
      (Forest_index.resolve forest index ~documents:[ doc ]))

let test_asset_unsafe_destination () =
  with_fixture (fun root ->
    let doc = image_doc ~root ~destination:"../outside/x.png" in
    let index = expect_build "unsafe index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    expect_code "unsafe destination" "TM205"
      (Forest_index.resolve forest index ~documents:[ doc ]))

(* ── end-to-end: everything resolvable at once ── *)

let render_diagnostics name diagnostics =
  let messages =
    List.map (fun d ->
      Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code)
        d.Diagnostic.message)
      diagnostics
    |> String.concat "; "
  in
  name ^ ": " ^ messages

(* An editor that addresses notes by filename writes `[[beta.tree]]` for the
   tree stored in `beta.tree.md`, whose identity is `beta`. *)
let test_tree_suffix_reference_resolves () =
  with_fixture (fun root ->
    let alpha =
      parse_doc ~root_id:"alpha" ~path:(Filename.concat root "trees-md/alpha.tree.md")
        "# Alpha\n\n[[beta.tree]]\n\n![[gamma.tree]]\n"
    in
    let beta =
      parse_doc ~root_id:"beta" ~path:(Filename.concat root "trees-md/beta.tree.md")
        "# Beta\n"
    in
    let gamma =
      parse_doc ~root_id:"gamma" ~path:(Filename.concat root "trees-md/gamma.tree.md")
        "# Gamma\n"
    in
    let documents = [ alpha; beta; gamma ] in
    let index = expect_build "suffix index" ~handwritten:[] ~generated:documents in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents with
    | Error diagnostics ->
      Alcotest.fail (render_diagnostics "suffixed references rejected" diagnostics)
    | Ok results ->
      let resolution = List.assoc "alpha" results in
      let ids =
        List.map
          (fun (r : Ir.reference) -> Resolution.tree_id resolution r.Ir.span)
          alpha.Parsed_document.references
        |> List.sort compare
      in
      Alcotest.(check (list (option string))) "both rewritten to the identity"
        [ Some "beta"; Some "gamma" ] ids)

(* The exact identity is tried first, so a tree really named `beta.tree` is not
   shadowed by the fallback. *)
let test_tree_suffix_exact_match_wins () =
  with_fixture (fun root ->
    let alpha =
      parse_doc ~root_id:"alpha" ~path:(Filename.concat root "trees-md/alpha.tree.md")
        "# Alpha\n\n[[beta.tree]]\n"
    in
    let beta =
      parse_doc ~root_id:"beta" ~path:(Filename.concat root "trees-md/beta.tree.md")
        "# Beta\n"
    in
    let beta_tree =
      parse_doc ~root_id:"beta.tree"
        ~path:(Filename.concat root "trees-md/beta.tree.tree.md")
        "# Beta tree\n"
    in
    let documents = [ alpha; beta; beta_tree ] in
    let index = expect_build "exact index" ~handwritten:[] ~generated:documents in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents with
    | Error diagnostics ->
      Alcotest.fail (render_diagnostics "exact match rejected" diagnostics)
    | Ok results ->
      let resolution = List.assoc "alpha" results in
      let reference = List.hd alpha.Parsed_document.references in
      Alcotest.(check (option string)) "no rewrite recorded" None
        (Resolution.tree_id resolution reference.Ir.span))

let test_tree_suffix_unresolved_still_errors () =
  with_fixture (fun root ->
    let doc =
      parse_doc ~root_id:"a" ~path:(Filename.concat root "trees-md/a.tree.md")
        "# A\n\n![[missing.tree]]\n"
    in
    let index = expect_build "missing index" ~handwritten:[] ~generated:[ doc ] in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    Forest_index.resolve forest index ~documents:[ doc ]
    |> expect_code "suffixed miss" "TM202")

let test_forest_wide_resolution_ok () =
  with_fixture (fun root ->
    write_file (Filename.concat root "assets/images/x.png") "image\n";
    let alpha_path = Filename.concat root "trees-md/alpha.tree.md" in
    let beta_path = Filename.concat root "trees-md/beta.tree.md" in
    let alpha_text =
      "---\n" ^
      "authors: [\"Ada Lovelace\"]\n" ^
      "---\n# Alpha\n\n[[beta]]\n\n![[gamma]]\n\n\
       [visit](notes/other.md)\n\n![Plot](images/x.png)\n"
    in
    let alpha =
      parse_doc ~root_id:"alpha" ~path:alpha_path alpha_text
    in
    let beta = parse_doc ~root_id:"beta" ~path:beta_path "# Beta\n" in
    let gamma = parse_doc ~root_id:"gamma" ~path:(Filename.concat root "trees-md/gamma.tree.md") "# Gamma\n" in
    let handwritten =
      [ { Discovery.id = "manual"; path = Filename.concat root "trees/manual.tree" } ]
    in
    let index =
      expect_build "forest-wide index" ~handwritten
        ~generated:[ alpha; beta; gamma ]
    in
    let forest = make_forest ~root ~asset_roots:["assets"] in
    match Forest_index.resolve forest index ~documents:[ alpha; beta; gamma ] with
    | Ok results ->
      Alcotest.(check (list string)) "one resolution per document"
        [ "alpha"; "beta"; "gamma" ] (List.map fst results);
      let alpha_resolution =
        List.assoc "alpha" results
      in
      Alcotest.(check (option string)) "routed asset path"
        (Some "assets/images/x.png")
        (Resolution.asset_route alpha_resolution (asset_span alpha))
    | Error diagnostics ->
      let messages = List.map (fun d -> d.Diagnostic.message) diagnostics in
      Alcotest.fail ("forest-wide resolution rejected: "
                     ^ String.concat "; " messages))

let () =
  let open Alcotest in
  run "Forest_index"
    [ "build", [
        test_case "duplicate_generated_roots" `Quick test_duplicate_generated_roots;
        test_case "duplicate_subtree_orders_by_byte" `Quick test_duplicate_subtree_orders_by_byte;
        test_case "root_versus_named_subtree" `Quick test_root_versus_named_subtree;
        test_case "two_named_subtrees" `Quick test_two_named_subtrees;
        test_case "generated_versus_handwritten_root" `Quick test_generated_versus_handwritten_root;
        test_case "clean_forest_builds" `Quick test_clean_forest_builds;
      ]
    ; "references", [
        test_case "unresolved_wiki_link" `Quick test_unresolved_wiki_link;
        test_case "unresolved_embed" `Quick test_unresolved_embed;
        test_case "unresolved_attributions" `Quick test_unresolved_attributions;
        test_case "literal_and_plain_link_ignored" `Quick test_literal_attribution_and_plain_link_ignored;
        test_case "tree_suffix_resolves" `Quick test_tree_suffix_reference_resolves;
        test_case "tree_suffix_exact_match_wins" `Quick test_tree_suffix_exact_match_wins;
        test_case "tree_suffix_unresolved_errors" `Quick test_tree_suffix_unresolved_still_errors;
      ]
    ; "assets", [
        test_case "zero_matches_tm203" `Quick test_asset_zero_matches;
        test_case "ambiguous_two_roots_tm204" `Quick test_asset_ambiguous_two_roots;
        test_case "single_match_routes" `Quick test_asset_single_match_routes;
        test_case "symlink_file_escape_tm205" `Quick test_asset_symlink_file_escape;
        test_case "symlinked_directory_escape_tm205" `Quick test_asset_symlinked_directory_escape;
        test_case "hidden_destination_tm205" `Quick test_asset_hidden_destination;
        test_case "unsafe_destination_tm205" `Quick test_asset_unsafe_destination;
      ]
    ; "forest_wide", [
        test_case "forest_wide_resolution_ok" `Quick test_forest_wide_resolution_ok;
      ]
    ]
