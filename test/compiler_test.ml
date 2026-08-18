open Tree_md

(* Each compile stage now returns its warnings alongside the value it
   produced. These suites assert on the value, so they drop the warnings. *)
let parse_doc ~root_id source =
  Result.map fst (Compiler.parse ~default_id:root_id ~filename:root_id source)
let emit_doc ~resolution doc = Result.map fst (Compiler.emit ~resolution doc)

let str_contains s sub =
  let len = String.length s in
  let sublen = String.length sub in
  let rec loop i =
    if i > len - sublen then false
    else if String.sub s i sublen = sub then true
    else loop (i + 1)
  in
  sublen <= len && loop 0

let read_fixture path =
  let ch = open_in path in
  let len = in_channel_length ch in
  let buf = Bytes.create len in
  really_input ch buf 0 len;
  close_in ch;
  Bytes.unsafe_to_string buf

let resolve_fixture_path relative =
  let sandbox_path = Filename.concat "fixtures" relative in
  if Sys.file_exists sandbox_path then sandbox_path
  else Filename.concat "tools/tree-md/test/fixtures" relative

let source_from_string text =
  match Source.of_string ~path:"test.md" text with
  | Ok src -> src
  | Error _ -> failwith "invalid UTF-8 in source"

let test_golden_complete () =
  let src_path = resolve_fixture_path "markdown/complete.tree.md" in
  let golden_path = resolve_fixture_path "forester/complete.tree" in
  let source = match Source.of_string ~path:src_path (read_fixture src_path) with
    | Ok s -> s
    | Error _ -> failwith ("invalid UTF-8 in fixture: " ^ src_path)
  in
  let doc = match parse_doc ~root_id:"complete" source with
    | Ok d -> d
    | Error diags ->
      let msgs = List.map (fun d ->
        Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code) d.Diagnostic.message
      ) diags |> String.concat "\n" in
      failwith ("parse failed:\n" ^ msgs)
  in
  let resolution =
    List.fold_left (fun res (asset : Parsed_document.local_asset) ->
      let routed = "assets/" ^ asset.destination in
      Resolution.add_asset asset.span ~routed_path:routed res
    ) Resolution.empty doc.Parsed_document.local_assets
  in
  let result = match emit_doc ~resolution doc with
    | Ok s -> s
    | Error diags ->
      let msgs = List.map (fun d ->
        Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code) d.Diagnostic.message
      ) diags |> String.concat "\n" in
      failwith ("emit failed:\n" ^ msgs)
  in
  let expected = read_fixture golden_path in
  Alcotest.(check string) "golden complete" expected result

let test_roundtrip_deterministic () =
  let source = source_from_string "---
date: 2026-08-02
---

# Test

[[ref1]] and [[ref2]].

<!-- subtree: sec-1 -->
## Section

Body with ![img](local/a.png).
" in
  let doc1 = match parse_doc ~root_id:"test" source with
    | Ok d -> d
    | Error diags ->
      let msgs = List.map (fun d ->
        Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code) d.Diagnostic.message
      ) diags |> String.concat "; " in
      failwith ("parse1 failed: " ^ msgs)
  in
  let doc2 = match parse_doc ~root_id:"test" source with
    | Ok d -> d
    | Error _ -> failwith "parse2 failed"
  in
  Alcotest.(check (list string)) "same definitions"
    (List.map (fun (d : Outline.definition) -> d.Outline.id) doc1.Parsed_document.definitions)
    (List.map (fun (d : Outline.definition) -> d.Outline.id) doc2.Parsed_document.definitions);
  Alcotest.(check (list string)) "same references"
    (List.map (fun (r : Ir.reference) -> r.Ir.target) doc1.Parsed_document.references)
    (List.map (fun (r : Ir.reference) -> r.Ir.target) doc2.Parsed_document.references);
  let resolution =
    List.fold_left (fun res (asset : Parsed_document.local_asset) ->
      Resolution.add_asset asset.span ~routed_path:("root/" ^ asset.destination) res
    ) Resolution.empty doc1.Parsed_document.local_assets
  in
  let out1 = match emit_doc ~resolution doc1 with
    | Ok s -> s
    | Error _ -> failwith "emit1 failed"
  in
  let out2 = match emit_doc ~resolution doc2 with
    | Ok s -> s
    | Error _ -> failwith "emit2 failed"
  in
  Alcotest.(check string) "deterministic output" out1 out2

let test_html_comment_inline_discarded () =
  let source = source_from_string "<!-- comment -->\n\nParagraph text." in
  let doc = match parse_doc ~root_id:"test" source with
    | Ok d -> d
    | Error diags ->
      let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
      failwith ("parse should not error on HTML comments: " ^ msgs)
  in
  let result = match emit_doc ~resolution:Resolution.empty doc with
    | Ok s -> s
    | Error diags ->
      let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
      failwith ("emit should not error: " ^ msgs)
  in
  Alcotest.(check bool) "comment discarded"
    true (not (str_contains (String.lowercase_ascii result) "comment"));
  Alcotest.(check bool) "paragraph preserved"
    true (str_contains (String.lowercase_ascii result) "paragraph text")

let test_html_comment_block_discarded () =
  let source = source_from_string "# Test\n\n<!-- subtree: sec -->\n## Named" in
  let doc = match parse_doc ~root_id:"test" source with
    | Ok d -> d
    | Error diags ->
      let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
      failwith ("parse failed: " ^ msgs)
  in
  Alcotest.(check (list string)) "definitions has sec"
    ["sec"] (List.map (fun (d : Outline.definition) -> d.Outline.id) doc.Parsed_document.definitions)

(* ── Inline wiki links with surrounding text: no stray bracket literals ──
   Cmarkit merges the wiki envelope's outermost `[`/`]` into adjacent Text
   runs; the wrapper filter must strip exactly those bracket bytes so the
   emitted paragraph is the raw wiki link with clean surrounding text. *)

let test_wiki_link_clean_surrounding_text () =
  let source = source_from_string "---
date: 2026-08-04
---

# Wiki Cleanliness

Plain wiki: [[manual]].

Prefix [[manual]] and [[notes]] suffix.

**bold** before [[manual]] after.
" in
  let doc = match parse_doc ~root_id:"test" source with
    | Ok d -> d
    | Error diags ->
      let msgs = List.map (fun d ->
        Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code) d.Diagnostic.message
      ) diags |> String.concat "\n" in
      failwith ("parse failed:\n" ^ msgs)
  in
  let result = match emit_doc ~resolution:Resolution.empty doc with
    | Ok s -> s
    | Error diags ->
      let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
      failwith ("emit failed: " ^ msgs)
  in
  (* No stray escaped bracket fragments anywhere in the emitted output *)
  Alcotest.(check bool) "no stray open bracket escape"
    false (str_contains result "\\verbFMD|[FMD");
  Alcotest.(check bool) "no stray close bracket escape"
    false (str_contains result "\\verbFMD|]FMD");
  (* The wiki links are emitted raw and the surrounding text is intact *)
  Alcotest.(check bool) "first paragraph clean"
    true (str_contains result "\\p{Plain wiki: [[manual]].}");
  Alcotest.(check bool) "middle paragraph clean"
    true (str_contains result "\\p{Prefix [[manual]] and [[notes]] suffix.}");
  Alcotest.(check bool) "emphasis paragraph clean"
    true (str_contains result "\\p{\\strong{bold} before [[manual]] after.}")

let test_subtree_directive_invalid_id () =
  (* An invalid directive ID is a TM104 source error: the document fails to
     parse, so no `\subtree[...]` section is ever emitted. *)
  let source = source_from_string "# Root\n\n<!-- subtree: bad id -->\n## Section\n" in
  match parse_doc ~root_id:"test" source with
  | Ok _ -> Alcotest.fail "expected TM104 for invalid subtree directive ID"
  | Error diags ->
    Alcotest.(check bool) "TM104 present" true
      (List.exists (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM104") diags)

let () =
  let open Alcotest in
  run "Compiler"
    [ "integration", [
        test_case "golden_complete" `Quick test_golden_complete;
      ]
    ; "determinism", [
        test_case "roundtrip_deterministic" `Quick test_roundtrip_deterministic;
      ]
    ; "html_comments", [
        test_case "html_comment_inline_discarded" `Quick test_html_comment_inline_discarded;
        test_case "html_comment_block_discarded" `Quick test_html_comment_block_discarded;
      ]
    ; "wiki_cleanliness", [
        test_case "wiki_link_clean_surrounding_text" `Quick test_wiki_link_clean_surrounding_text;
      ]
    ; "subtree_directives", [
        test_case "subtree_directive_invalid_id" `Quick test_subtree_directive_invalid_id;
      ]
    ]
