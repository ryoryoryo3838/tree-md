let source_from_string text =
  Result.get_ok (Tree_md.Source.of_string ~path:"test.md" text)

let mask_all text = text

let parse text =
  let src = source_from_string text in
  Tree_md.Markdown.parse src ~masked_markdown: text Tree_md.Metadata.empty

let parse_result text =
  let src = source_from_string text in
  Tree_md.Markdown.parse src ~masked_markdown: text Tree_md.Metadata.empty

let has_diag_code diags code =
  List.exists (fun d -> Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code = code) diags

let rec node_to_string = function
  | Tree_md.Ir.Text s -> Printf.sprintf "Text(%S)" s
  | Tree_md.Ir.Emphasis _ -> "Emphasis"
  | Tree_md.Ir.Strong _ -> "Strong"
  | Tree_md.Ir.Code s -> Printf.sprintf "Code(%S)" s
  | Tree_md.Ir.Link { label = lbl; destination = d; title = _ } ->
    let label_str = String.concat " " (List.map (fun i -> node_to_string i.Tree_md.Ir.node) lbl) in
    Printf.sprintf "Link(%S)[%s]" d label_str
  | Tree_md.Ir.Image { alt = a; destination = d; title = _ } ->
    let alt_str = String.concat " " (List.map (fun i -> node_to_string i.Tree_md.Ir.node) a) in
    Printf.sprintf "Image(%S)[%s]" d alt_str
  | Tree_md.Ir.Wiki_link { target = t; alias = a } ->
    let alias_str = match a with None -> "" | Some s -> Printf.sprintf " alias=%S" s in
    Printf.sprintf "WikiLink(%S%s)" t alias_str
  | Tree_md.Ir.Wiki_embed t -> Printf.sprintf "WikiEmbed(%S)" t
  | Tree_md.Ir.Math { tex = t; display = d } ->
    Printf.sprintf "Math(%S %b)" t d
  | Tree_md.Ir.Hard_break -> "HardBreak"
  | Tree_md.Ir.Soft_break -> "SoftBreak"

let block_node_to_string = function
  | Tree_md.Ir.Paragraph inlines ->
    let parts = List.map (fun i -> node_to_string i.Tree_md.Ir.node) inlines in
    Printf.sprintf "Paragraph[%s]" (String.concat " " parts)
  | Tree_md.Ir.Blockquote _ -> "Blockquote"
  | Tree_md.Ir.List { kind; tight; items } ->
    let kind_str = match kind with
      | Tree_md.Ir.Unordered -> "Unordered"
      | Tree_md.Ir.Ordered n -> Printf.sprintf "Ordered(%d)" n
    in
    let tight_str = if tight then "tight" else "loose" in
    Printf.sprintf "List(%s %s %d items)" kind_str tight_str (List.length items)
  | Tree_md.Ir.Code_block { info; code } ->
    let info_str = match info with
      | Tree_md.Ir.No_info -> "NoInfo"
      | Tree_md.Ir.Language lang -> Printf.sprintf "Lang(%S)" lang
    in
    Printf.sprintf "CodeBlock(%s %S)" info_str code
  | Tree_md.Ir.Thematic_break -> "ThematicBreak"
  | Tree_md.Ir.Heading { level; title } ->
    let parts = List.map (fun i -> node_to_string i.Tree_md.Ir.node) title in
    Printf.sprintf "Heading(%d)[%s]" level (String.concat " " parts)
  | Tree_md.Ir.Subtree_directive id -> Printf.sprintf "Subtree(%S)" id
  | Tree_md.Ir.Block_embed id -> Printf.sprintf "Embed(%S)" id
  | Tree_md.Ir.Display_math tex -> Printf.sprintf "DisplayMath(%S)" tex

(* ── Basic block fixtures ── *)

let test_paragraph () =
  match parse "hello world" with
  | Ok doc ->
    Alcotest.(check int) "one block" 1 (List.length doc.blocks);
    Alcotest.(check string) "paragraph"
      "Paragraph[Text(\"hello world\")]"
      (block_node_to_string (List.hd doc.blocks).bnode)
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_blockquote () =
  match parse "> quoted text" with
  | Ok doc ->
    Alcotest.(check int) "one block" 1 (List.length doc.blocks);
    (match doc.blocks with
     | [b] ->
       Alcotest.(check string) "blockquote"
         "Blockquote"
         (block_node_to_string b.bnode)
     | _ -> Alcotest.fail "expected one block")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_nested_blockquote () =
  match parse "> > nested" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Blockquote inner; _ }] ->
       (match inner with
        | [{ bnode = Tree_md.Ir.Blockquote _; _ }] -> ()
        | _ -> Alcotest.fail "expected nested blockquote")
     | _ -> Alcotest.fail "expected Blockquote")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_tight_list () =
  match parse "- a\n- b" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { tight = true; items; _ }; _ }] ->
       Alcotest.(check int) "two items" 2 (List.length items)
     | _ -> Alcotest.fail "expected tight list")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_loose_list () =
  match parse "- a\n\n- b" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { tight = false; items; _ }; _ }] ->
       Alcotest.(check int) "two items" 2 (List.length items)
     | _ -> Alcotest.fail "expected loose list")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_nested_list () =
  match parse "- a\n  - b" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { items; _ }; _ }] ->
       (match items with
        | [item] ->
          (match item.item_blocks with
           | [{ bnode = Tree_md.Ir.Paragraph _; _ };
              { bnode = Tree_md.Ir.List _; _ }] -> ()
           | _ -> Alcotest.fail "expected paragraph then nested list in item")
        | _ -> Alcotest.fail "expected one list item")
     | _ -> Alcotest.fail "expected List")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_ordered_start_1 () =
  match parse "1. a\n2. b" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { kind = Tree_md.Ir.Ordered 1; items; _ }; _ }] ->
       Alcotest.(check int) "two items" 2 (List.length items)
     | _ -> Alcotest.fail "expected Ordered(1)")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_ordered_start_7 () =
  match parse "7. a\n8. b" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { kind = Tree_md.Ir.Ordered 7; items; _ }; _ }] ->
       Alcotest.(check int) "two items" 2 (List.length items)
     | _ -> Alcotest.fail "expected Ordered(7)")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_indented_code () =
  match parse "    code" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { info = Tree_md.Ir.No_info; code }; _ }] ->
       Alcotest.(check string) "indented code" "code" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_fenced_code_no_lang () =
  match parse "```\ncode\n```" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { info = Tree_md.Ir.No_info; code }; _ }] ->
       Alcotest.(check string) "fenced no lang" "code" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_fenced_code_ocaml () =
  match parse "```ocaml\nlet x = 1\n```" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { info = Tree_md.Ir.Language "ocaml"; code }; _ }] ->
       Alcotest.(check string) "fenced ocaml" "let x = 1" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_thematic_break () =
  match parse "---" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Thematic_break; _ }] -> ()
     | _ -> Alcotest.fail "expected ThematicBreak")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_atx_heading () =
  match parse "# Title" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Heading { level = 1; title; _ }; _ }] ->
       Alcotest.(check string) "atx heading"
         "Heading(1)[Text(\"Title\")]"
         (block_node_to_string (List.hd doc.blocks).bnode)
     | _ -> Alcotest.fail "expected Heading(1)")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_setext_heading () =
  match parse "Title\n===" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Heading { level = 1; _ }; _ }] -> ()
     | _ -> Alcotest.fail "expected Heading(1)")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_comment_discarded () =
  match parse "text\n<!-- ordinary comment -->\nmore" with
  | Ok doc ->
    Alcotest.(check int) "two blocks (comment discarded)" 2 (List.length doc.blocks)
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Subtree directive ── *)

let test_subtree_directive () =
  match parse "<!-- subtree: my.tree -->" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Subtree_directive "my.tree"; _ }] -> ()
     | _ -> Alcotest.fail "expected Subtree_directive")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_subtree_directive_invalid_id () =
  match parse "<!-- subtree: bad id -->" with
  | Ok doc ->
    let has_directive = List.exists (fun b ->
      match b.Tree_md.Ir.bnode with
      | Tree_md.Ir.Subtree_directive _ -> true
      | _ -> false) doc.blocks in
    Alcotest.(check bool) "no Subtree_directive block for invalid id" false has_directive
  | Error diags ->
    Alcotest.(check bool) "invalid id TM104" true (has_diag_code diags "TM104")

(* ── Embed normalization ── *)

let test_embed_normalization () =
  match parse "![[note]]" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Block_embed "note"; _ }] -> ()
     | _ -> Alcotest.fail "expected Embed")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Display math normalization ── *)

let test_display_math_normalization () =
  match parse "$$x+y$$" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Display_math "x+y"; _ }] -> ()
     | _ -> Alcotest.fail "expected Display_math")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Diagnostic: raw block HTML ── *)

let test_raw_html_block_rejected () =
  match parse "<div>block</div>\n" with
  | Error diags ->
    Alcotest.(check bool) "raw block HTML TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for raw block HTML"

(* ── Diagnostic: GFM table ── *)

let test_gfm_table_rejected () =
  match parse "| a | b |\n| - | - |\n| 1 | 2 |" with
  | Error diags ->
    Alcotest.(check bool) "GFM table TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for GFM table"

(* ── Diagnostic: task marker ── *)

let test_task_marker_rejected () =
  match parse "- [ ] task" with
  | Error diags ->
    Alcotest.(check bool) "task marker TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for task marker"

(* ── Diagnostic: footnote ── *)

let test_footnote_rejected () =
  match parse "[^1]: note" with
  | Error diags ->
    Alcotest.(check bool) "footnote TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for footnote"

(* ── Diagnostic: fenced math (reject exactly "math") ── *)

let test_fenced_math_rejected () =
  match parse "```math\nx=1\n```" with
  | Error diags ->
    Alcotest.(check bool) "fenced math TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for fenced math"

(* ── Diagnostic: multi-token fence info ── *)

let test_multi_token_fence_rejected () =
  match parse "```ocaml foo\ncode\n```" with
  | Error diags ->
    Alcotest.(check bool) "multi-token fence TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for multi-token fence info"

(* ── Diagnostic: invalid language token ── *)

let test_invalid_lang_token_rejected () =
  match parse "```@invalid\ncode\n```" with
  | Error diags ->
    Alcotest.(check bool) "invalid lang token TM102" true (has_diag_code diags "TM102")
  | Ok _ -> Alcotest.fail "expected TM102 for invalid language token"

(* ── Diagnostic: nested heading ── *)

let test_nested_heading_rejected () =
  match parse "> # heading in blockquote" with
  | Error diags ->
    Alcotest.(check bool) "nested heading TM103" true (has_diag_code diags "TM103")
  | Ok _ -> Alcotest.fail "expected TM103 for nested heading"

(* ── Diagnostic: inline embed ── *)

let test_inline_embed_rejected () =
  match parse "text ![[note]] more" with
  | Error diags ->
    Alcotest.(check bool) "inline embed TM106" true (has_diag_code diags "TM106")
  | Ok _ -> Alcotest.fail "expected TM106 for inline embed"

(* ── Diagnostic: embed in list ── *)

let test_embed_in_list_rejected () =
  match parse "- ![[note]]" with
  | Error diags ->
    Alcotest.(check bool) "embed in list TM106" true (has_diag_code diags "TM106")
  | Ok _ -> Alcotest.fail "expected TM106 for embed in list"

(* ── Diagnostic: embed in blockquote ── *)

let test_embed_in_blockquote_rejected () =
  match parse "> ![[note]]" with
  | Error diags ->
    Alcotest.(check bool) "embed in blockquote TM106" true (has_diag_code diags "TM106")
  | Ok _ -> Alcotest.fail "expected TM106 for embed in blockquote"

(* ── Diagnostic: inline display math ── *)

let test_inline_display_math_rejected () =
  match parse "text $$x$$ more" with
  | Error diags ->
    Alcotest.(check bool) "inline display math TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for inline display math"

(* ── Diagnostic: display math in list ── *)

let test_display_math_in_list_rejected () =
  match parse "- $$x$$" with
  | Error diags ->
    Alcotest.(check bool) "display math in list TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for display math in list"

(* ── Diagnostic: display math in blockquote ── *)

let test_display_math_in_blockquote_rejected () =
  match parse "> $$x$$" with
  | Error diags ->
    Alcotest.(check bool) "display math in blockquote TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for display math in blockquote"

(* ── Regression: inline display math with text ── *)

let test_text_and_display_math_rejected () =
  match parse "text $$x+y$$" with
  | Error diags ->
    Alcotest.(check bool) "text+display math TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for text+display math"

(* ── Regression: inline embed with text ── *)

let test_text_and_embed_rejected () =
  match parse "text ![[note]]" with
  | Error diags ->
    Alcotest.(check bool) "text+embed TM106" true (has_diag_code diags "TM106")
  | Ok _ -> Alcotest.fail "expected TM106 for text+embed"

(* ── Regression: code block protects special syntax ── *)

let test_code_block_protects_math () =
  match parse "```\n$$x$$\n```" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { code; _ }; _ }] ->
       Alcotest.(check string) "code protects math" "$$x$$" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_code_block_protects_wiki () =
  match parse "```\n![[note]]\n```" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { code; _ }; _ }] ->
       Alcotest.(check string) "code protects wiki" "![[note]]" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Regression: nested blockquote creates TM103 but outer still works ── *)

let test_blockquote_deep_structure () =
  match parse "> text\n> > inner quote" with
  | Ok doc ->
    Alcotest.(check int) "one blockquote" 1 (List.length doc.blocks)
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Regression: list with ordered start preserved ── *)

let test_list_ordered_start_preserved () =
  match parse "42. first\n43. second" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { kind = Tree_md.Ir.Ordered 42; items; _ }; _ }] ->
       Alcotest.(check int) "two items" 2 (List.length items)
     | _ -> Alcotest.fail "expected Ordered(42)")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Regression: tightness flag preserved ── *)

let test_list_tightness_preserved () =
  match parse "- tight a\n- tight b" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.List { tight = true; items; _ }; _ }] ->
       Alcotest.(check int) "tight items" 2 (List.length items)
     | _ -> Alcotest.fail "expected tight list")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Regression: multi-line code blocks preserve line separators ── *)

let test_indented_code_multi_line () =
  match parse "    line1\n    line2" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { info = Tree_md.Ir.No_info; code }; _ }] ->
       Alcotest.(check string) "indented multi-line" "line1\nline2" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_fenced_code_multi_line () =
  match parse "```\nline1\nline2\n```" with
  | Ok doc ->
    (match doc.blocks with
     | [{ bnode = Tree_md.Ir.Code_block { info = Tree_md.Ir.No_info; code }; _ }] ->
       Alcotest.(check string) "fenced multi-line" "line1\nline2" code
     | _ -> Alcotest.fail "expected CodeBlock")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Regression: nested embed/display-math in blockquote > list contexts ── *)

let test_embed_in_blockquote_list_rejected () =
  match parse "> - ![[note]]" with
  | Error diags ->
    Alcotest.(check bool) "embed in blockquote list TM106" true (has_diag_code diags "TM106")
  | Ok _ -> Alcotest.fail "expected TM106 for embed in blockquote list"

let test_display_math_in_blockquote_list_rejected () =
  match parse "> - $$x$$" with
  | Error diags ->
    Alcotest.(check bool) "display math in blockquote list TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for display math in blockquote list"

(* ── Sanity: document span is valid ── *)

let test_document_span () =
  match parse "# Title\n\ntext" with
  | Ok doc ->
    let sp = doc.doc_span in
    Alcotest.(check bool) "span start_byte >= 0" true (sp.Tree_md.Span.start_byte >= 0);
    Alcotest.(check bool) "span end_byte >= start_byte" true (sp.Tree_md.Span.end_byte >= sp.Tree_md.Span.start_byte)
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Run ── *)

let () =
  let open Alcotest in
  run "Block"
    [ "paragraph", [ test_case "paragraph" `Quick test_paragraph ]
    ; "blockquote", [ test_case "blockquote" `Quick test_blockquote ]
    ; "nested_blockquote", [ test_case "nested_blockquote" `Quick test_nested_blockquote ]
    ; "tight_list", [ test_case "tight_list" `Quick test_tight_list ]
    ; "loose_list", [ test_case "loose_list" `Quick test_loose_list ]
    ; "nested_list", [ test_case "nested_list" `Quick test_nested_list ]
    ; "ordered_start_1", [ test_case "ordered_start_1" `Quick test_ordered_start_1 ]
    ; "ordered_start_7", [ test_case "ordered_start_7" `Quick test_ordered_start_7 ]
    ; "indented_code", [ test_case "indented_code" `Quick test_indented_code ]
    ; "fenced_code_no_lang", [ test_case "fenced_code_no_lang" `Quick test_fenced_code_no_lang ]
    ; "fenced_code_ocaml", [ test_case "fenced_code_ocaml" `Quick test_fenced_code_ocaml ]
    ; "thematic_break", [ test_case "thematic_break" `Quick test_thematic_break ]
    ; "atx_heading", [ test_case "atx_heading" `Quick test_atx_heading ]
    ; "setext_heading", [ test_case "setext_heading" `Quick test_setext_heading ]
    ; "comment_discarded", [ test_case "comment_discarded" `Quick test_comment_discarded ]
    ; "subtree_directive", [ test_case "subtree_directive" `Quick test_subtree_directive ]
    ; "subtree_directive_invalid_id", [ test_case "subtree_directive_invalid_id" `Quick test_subtree_directive_invalid_id ]
    ; "embed_normalization", [ test_case "embed_normalization" `Quick test_embed_normalization ]
    ; "display_math_normalization", [ test_case "display_math_normalization" `Quick test_display_math_normalization ]
    ; "raw_html_block_rejected", [ test_case "raw_html_block_rejected" `Quick test_raw_html_block_rejected ]
    ; "gfm_table_rejected", [ test_case "gfm_table_rejected" `Quick test_gfm_table_rejected ]
    ; "task_marker_rejected", [ test_case "task_marker_rejected" `Quick test_task_marker_rejected ]
    ; "footnote_rejected", [ test_case "footnote_rejected" `Quick test_footnote_rejected ]
    ; "fenced_math_rejected", [ test_case "fenced_math_rejected" `Quick test_fenced_math_rejected ]
    ; "multi_token_fence_rejected", [ test_case "multi_token_fence_rejected" `Quick test_multi_token_fence_rejected ]
    ; "invalid_lang_token_rejected", [ test_case "invalid_lang_token_rejected" `Quick test_invalid_lang_token_rejected ]
    ; "nested_heading_rejected", [ test_case "nested_heading_rejected" `Quick test_nested_heading_rejected ]
    ; "inline_embed_rejected", [ test_case "inline_embed_rejected" `Quick test_inline_embed_rejected ]
    ; "embed_in_list_rejected", [ test_case "embed_in_list_rejected" `Quick test_embed_in_list_rejected ]
    ; "embed_in_blockquote_rejected", [ test_case "embed_in_blockquote_rejected" `Quick test_embed_in_blockquote_rejected ]
    ; "inline_display_math_rejected", [ test_case "inline_display_math_rejected" `Quick test_inline_display_math_rejected ]
    ; "display_math_in_list_rejected", [ test_case "display_math_in_list_rejected" `Quick test_display_math_in_list_rejected ]
    ; "display_math_in_blockquote_rejected", [ test_case "display_math_in_blockquote_rejected" `Quick test_display_math_in_blockquote_rejected ]
    ; "text_and_display_math_rejected", [ test_case "text_and_display_math_rejected" `Quick test_text_and_display_math_rejected ]
    ; "text_and_embed_rejected", [ test_case "text_and_embed_rejected" `Quick test_text_and_embed_rejected ]
    ; "code_block_protects_math", [ test_case "code_block_protects_math" `Quick test_code_block_protects_math ]
    ; "code_block_protects_wiki", [ test_case "code_block_protects_wiki" `Quick test_code_block_protects_wiki ]
    ; "blockquote_deep_structure", [ test_case "blockquote_deep_structure" `Quick test_blockquote_deep_structure ]
    ; "list_ordered_start_preserved", [ test_case "list_ordered_start_preserved" `Quick test_list_ordered_start_preserved ]
    ; "list_tightness_preserved", [ test_case "list_tightness_preserved" `Quick test_list_tightness_preserved ]
    ; "document_span", [ test_case "document_span" `Quick test_document_span ]
    ; "indented_code_multi_line", [ test_case "indented_code_multi_line" `Quick test_indented_code_multi_line ]
    ; "fenced_code_multi_line", [ test_case "fenced_code_multi_line" `Quick test_fenced_code_multi_line ]
    ; "embed_in_blockquote_list_rejected", [ test_case "embed_in_blockquote_list_rejected" `Quick test_embed_in_blockquote_list_rejected ]
    ; "display_math_in_blockquote_list_rejected", [ test_case "display_math_in_blockquote_list_rejected" `Quick test_display_math_in_blockquote_list_rejected ]
    ]
