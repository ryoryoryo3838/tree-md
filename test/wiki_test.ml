let source_from_string text =
  Result.get_ok (Tree_md.Source.of_string ~path:"test.md" text)

let shapes_of text =
  let src = source_from_string text in
  match Tree_md.Wiki.shapes_for_test src text with
  | Ok (shapes, diags) -> (shapes, diags)
  | Error diags -> Alcotest.fail ("unexpected Error: " ^
      String.concat "; " (List.map
        (fun d -> d.Tree_md.Diagnostic.message) diags))

let span path start_byte end_byte =
  Result.get_ok (Tree_md.Span.make ~path ~start_byte ~end_byte)

let test_path = "test.md"

let shape_to_string = function
  | Tree_md.Wiki.Text_shape s ->
    Printf.sprintf "Text[%d,%d)" s.Tree_md.Span.start_byte s.Tree_md.Span.end_byte
  | Tree_md.Wiki.Code_shape s ->
    Printf.sprintf "Code[%d,%d)" s.Tree_md.Span.start_byte s.Tree_md.Span.end_byte
  | Tree_md.Wiki.Shortcut_shape c ->
    let kind_str = match c.Tree_md.Wiki.kind with Link -> "Link" | Embed -> "Embed" in
    let alias_str = match c.Tree_md.Wiki.alias with
      | None -> ""
      | Some a -> Printf.sprintf " alias=%S" a
    in
    Printf.sprintf "%s target=%S%s whole=[%d,%d) inner=[%d,%d)"
      kind_str c.Tree_md.Wiki.target alias_str
      c.Tree_md.Wiki.whole_span.Tree_md.Span.start_byte
      c.Tree_md.Wiki.whole_span.Tree_md.Span.end_byte
      c.Tree_md.Wiki.inner_span.Tree_md.Span.start_byte
      c.Tree_md.Wiki.inner_span.Tree_md.Span.end_byte
  | Tree_md.Wiki.Ordinary_link_shape s ->
    Printf.sprintf "OrdinaryLink[%d,%d)" s.Tree_md.Span.start_byte s.Tree_md.Span.end_byte

let shapes_to_string shapes =
  String.concat ", " (List.map shape_to_string shapes)

let has_code diags code =
  List.exists (fun d -> Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code = code) diags

(* ── Characterization: valid wiki forms ── *)

let test_simple_wiki_link () =
  let shapes, diags = shapes_of "[[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check int) "three shapes" 3 (List.length shapes);
  let _s = shapes_to_string shapes in
  Alcotest.(check bool) "has Text[0,1)" true
    (List.exists (fun s -> s = "Text[0,1)") (List.map shape_to_string shapes));
  Alcotest.(check bool) "has Shortcut Link id" true
    (List.exists (function
       | Tree_md.Wiki.Shortcut_shape c ->
         c.Tree_md.Wiki.kind = Tree_md.Wiki.Link
         && c.Tree_md.Wiki.target = "id"
         && c.Tree_md.Wiki.alias = None
         && c.Tree_md.Wiki.whole_span.Tree_md.Span.start_byte = 0
         && c.Tree_md.Wiki.whole_span.Tree_md.Span.end_byte = 6
         && c.Tree_md.Wiki.inner_span.Tree_md.Span.start_byte = 2
         && c.Tree_md.Wiki.inner_span.Tree_md.Span.end_byte = 4
       | _ -> false) shapes);
  Alcotest.(check bool) "has Text[5,6)" true
    (List.exists (function
       | Tree_md.Wiki.Text_shape s ->
         s.Tree_md.Span.start_byte = 5 && s.Tree_md.Span.end_byte = 6
       | _ -> false) shapes)

let test_wiki_link_with_alias () =
  let shapes, diags = shapes_of "[[id|alias]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check int) "three shapes" 3 (List.length shapes);
  Alcotest.(check bool) "has Shortcut Link with alias" true
    (List.exists (function
       | Tree_md.Wiki.Shortcut_shape c ->
         c.Tree_md.Wiki.kind = Tree_md.Wiki.Link
         && c.Tree_md.Wiki.target = "id"
         && c.Tree_md.Wiki.alias = Some "alias"
         && c.Tree_md.Wiki.whole_span.Tree_md.Span.start_byte = 0
         && c.Tree_md.Wiki.whole_span.Tree_md.Span.end_byte = 12
       | _ -> false) shapes)

let test_wiki_embed () =
  let shapes, diags = shapes_of "![[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "has Embed" true
    (List.exists (function
       | Tree_md.Wiki.Shortcut_shape c ->
         c.Tree_md.Wiki.kind = Tree_md.Wiki.Embed
         && c.Tree_md.Wiki.target = "id"
         && c.Tree_md.Wiki.whole_span.Tree_md.Span.start_byte = 0
         && c.Tree_md.Wiki.whole_span.Tree_md.Span.end_byte = 7
         && c.Tree_md.Wiki.inner_span.Tree_md.Span.start_byte = 3
         && c.Tree_md.Wiki.inner_span.Tree_md.Span.end_byte = 5
       | _ -> false) shapes)

(* ── Non-wiki: reference links never wiki ── *)

let test_reference_link_not_wiki () =
  let shapes, diags = shapes_of "[alias][[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Non-wiki: escaped ── *)

let test_escaped_not_wiki () =
  let shapes, diags = shapes_of "\\[[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Non-wiki: code span ── *)

let test_code_span_not_wiki () =
  let shapes, diags = shapes_of "`[[id]]`" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "has Code_shape" true
    (List.exists (function Tree_md.Wiki.Code_shape _ -> true | _ -> false) shapes);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── With reference definition: [alias][[id]] follows CommonMark ── *)

let test_reference_with_definition () =
  let text = "[id]: /ordinary\n\n[alias][[id]]\n" in
  let shapes, diags = shapes_of text in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Escaped wiki with definition still literal ── *)

let test_escaped_with_definition () =
  let text = "[id]: /ordinary\n\n\\[[id]]\n" in
  let shapes, diags = shapes_of text in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Backslash fixtures ── *)

let test_double_backslash_is_wiki () =
  let shapes, diags = shapes_of "\\\\[[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "is wiki (even backslashes)" true
    (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes)

let test_three_backslashes_not_wiki () =
  let shapes, diags = shapes_of "\\\\\\[[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "is not wiki (odd backslashes)" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Larger bracket runs ── *)

let test_larger_bracket_run () =
  let shapes, diags = shapes_of "[[[id]]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

let test_right_bracket_run () =
  let shapes, diags = shapes_of "[[id]]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

let test_left_bracket_run () =
  let shapes, diags = shapes_of "[[[id]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Invalid closed forms ── *)

let test_bad_id_diagnostic () =
  let _shapes, diags = shapes_of "[[bad id]]" in
  Alcotest.(check bool) "has TM105" true (has_code diags "TM105")

let test_empty_alias_diagnostic () =
  let _shapes, diags = shapes_of "[[id|]]" in
  Alcotest.(check bool) "has TM105" true (has_code diags "TM105")

let test_multiple_pipes_diagnostic () =
  let _shapes, diags = shapes_of "[[id|a|b]]" in
  Alcotest.(check bool) "has TM105" true (has_code diags "TM105")

(* ── Escaped pipe: [[id\|alias]] → no split (escaped), invalid target → TM105 ── *)

let test_escaped_pipe_no_split () =
  let _shapes, diags = shapes_of "[[id\\|alias]]" in
  Alcotest.(check bool) "has TM105" true (has_code diags "TM105")

(* ── Even backslashes before pipe: [[id\\|alias]] → split, invalid target → TM105 ── *)

let test_pipe_with_even_backslashes () =
  let _shapes, diags = shapes_of "[[id\\\\|alias]]" in
  Alcotest.(check bool) "has TM105" true (has_code diags "TM105")

(* ── Multiple unescaped pipes: [[a\\|b\\|c]] → TM105 ── *)

let test_multiple_unescaped_pipes_explicit () =
  let _shapes, diags = shapes_of "[[a\\\\|b\\\\|c]]" in
  Alcotest.(check bool) "has TM105" true (has_code diags "TM105")

(* ── Cross-paragraph: [[id across blank line is never wiki ── *)

let test_cross_paragraph_not_wiki () =
  let shapes, diags = shapes_of "[[id\n\n]]" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Wiki inside paragraph is fine (guard 5 passes) ── *)

let test_normal_paragraph_wiki () =
  let shapes, diags = shapes_of "text [[id]] more" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "has Shortcut_shape" true
    (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes)

let test_unclosed_is_literal () =
  let shapes, diags = shapes_of "[[id" in
  Alcotest.(check bool) "no diagnostics" true (diags = []);
  Alcotest.(check bool) "no Shortcut_shape" true
    (not (List.exists (function Tree_md.Wiki.Shortcut_shape _ -> true | _ -> false) shapes))

(* ── Repeated resolver calls (idempotent) ── *)

let test_repeated_calls () =
  let shapes1, _ = shapes_of "[[id]]" in
  let shapes2, _ = shapes_of "[[id]]" in
  Alcotest.(check int) "same shape count" (List.length shapes1) (List.length shapes2);
  Alcotest.(check string) "same shapes" (shapes_to_string shapes1) (shapes_to_string shapes2)

let test_second_call_same () =
  let src = source_from_string "[[id]]" in
  (match Tree_md.Wiki.shapes_for_test src "[[id]]" with
   | Ok (shapes1, _) ->
     (match Tree_md.Wiki.shapes_for_test src "[[id]]" with
      | Ok (shapes2, _) ->
        Alcotest.(check int) "same shape count" (List.length shapes1) (List.length shapes2)
      | Error diags ->
        Alcotest.fail ("unexpected Error: " ^
          String.concat "; " (List.map
            (fun d -> d.Tree_md.Diagnostic.message) diags)))
   | Error diags ->
     Alcotest.fail ("unexpected Error: " ^
       String.concat "; " (List.map
         (fun d -> d.Tree_md.Diagnostic.message) diags)))

let () =
  let open Alcotest in
  run "Wiki"
    [ "simple_wiki_link", [ test_case "simple_wiki_link" `Quick test_simple_wiki_link ]
    ; "wiki_link_with_alias", [ test_case "wiki_link_with_alias" `Quick test_wiki_link_with_alias ]
    ; "wiki_embed", [ test_case "wiki_embed" `Quick test_wiki_embed ]
    ; "reference_link_not_wiki", [ test_case "reference_link_not_wiki" `Quick test_reference_link_not_wiki ]
    ; "escaped_not_wiki", [ test_case "escaped_not_wiki" `Quick test_escaped_not_wiki ]
    ; "code_span_not_wiki", [ test_case "code_span_not_wiki" `Quick test_code_span_not_wiki ]
    ; "reference_with_definition", [ test_case "reference_with_definition" `Quick test_reference_with_definition ]
    ; "escaped_with_definition", [ test_case "escaped_with_definition" `Quick test_escaped_with_definition ]
    ; "double_backslash_is_wiki", [ test_case "double_backslash_is_wiki" `Quick test_double_backslash_is_wiki ]
    ; "three_backslashes_not_wiki", [ test_case "three_backslashes_not_wiki" `Quick test_three_backslashes_not_wiki ]
    ; "larger_bracket_run", [ test_case "larger_bracket_run" `Quick test_larger_bracket_run ]
    ; "right_bracket_run", [ test_case "right_bracket_run" `Quick test_right_bracket_run ]
    ; "left_bracket_run", [ test_case "left_bracket_run" `Quick test_left_bracket_run ]
    ; "bad_id_diagnostic", [ test_case "bad_id_diagnostic" `Quick test_bad_id_diagnostic ]
    ; "empty_alias_diagnostic", [ test_case "empty_alias_diagnostic" `Quick test_empty_alias_diagnostic ]
    ; "multiple_pipes_diagnostic", [ test_case "multiple_pipes_diagnostic" `Quick test_multiple_pipes_diagnostic ]
    ; "escaped_pipe_no_split", [ test_case "escaped_pipe_no_split" `Quick test_escaped_pipe_no_split ]
    ; "pipe_with_even_backslashes", [ test_case "pipe_with_even_backslashes" `Quick test_pipe_with_even_backslashes ]
    ; "multiple_unescaped_pipes_explicit", [ test_case "multiple_unescaped_pipes_explicit" `Quick test_multiple_unescaped_pipes_explicit ]
    ; "cross_paragraph_not_wiki", [ test_case "cross_paragraph_not_wiki" `Quick test_cross_paragraph_not_wiki ]
    ; "normal_paragraph_wiki", [ test_case "normal_paragraph_wiki" `Quick test_normal_paragraph_wiki ]
    ; "unclosed_is_literal", [ test_case "unclosed_is_literal" `Quick test_unclosed_is_literal ]
    ; "repeated_calls", [ test_case "repeated_calls" `Quick test_repeated_calls ]
    ; "second_call_same", [ test_case "second_call_same" `Quick test_second_call_same ]
    ]
