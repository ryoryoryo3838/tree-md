let make_span path start_byte end_byte =
  Result.get_ok (Tree_md.Span.make ~path ~start_byte ~end_byte)

let test_tm103_code () =
  Alcotest.(check string) "TM103 code string"
    "TM103" (Tree_md.Diagnostic.code_string TM103)

let test_sort_by_path_then_byte () =
  let span_a = make_span "a.md" 10 15 in
  let span_b = make_span "a.md" 5 8 in
  let span_c = make_span "b.md" 0 1 in
  let d_before =
    Tree_md.Diagnostic.make TM001 (Source_span span_a) "msg"
  in
  let d_after =
    Tree_md.Diagnostic.make TM001 (Source_span span_b) "msg"
  in
  let d_other_path =
    Tree_md.Diagnostic.make TM001 (Source_span span_c) "msg"
  in
  (* Same path: sort by byte *)
  Alcotest.(check bool) "same path byte order"
    true (Tree_md.Diagnostic.compare d_before d_after > 0);
  (* Different path: sort by path *)
  Alcotest.(check bool) "different path order"
    true (Tree_md.Diagnostic.compare d_other_path d_before > 0)

let test_path_location_sorts_after_span () =
  let span = make_span "a.md" 0 1 in
  let d_span =
    Tree_md.Diagnostic.make TM001 (Source_span span) "msg"
  in
  let d_path =
    Tree_md.Diagnostic.make TM001 (Path "a.md") "msg"
  in
  Alcotest.(check bool) "span before path"
    true (Tree_md.Diagnostic.compare d_path d_span > 0)

let test_no_location_sorts_last () =
  let d_path =
    Tree_md.Diagnostic.make TM001 (Path "a.md") "msg"
  in
  let d_no_loc =
    Tree_md.Diagnostic.make TM001 No_location "msg"
  in
  Alcotest.(check bool) "no_location last"
    true (Tree_md.Diagnostic.compare d_no_loc d_path > 0)

let test_tab_excerpt () =
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"tab.md" "\t\tcode")
  in
  let diag =
    Tree_md.Diagnostic.make TM103
      (Source_span (make_span "tab.md" 0 6)) "heading at wrong level"
  in
  let rendered = Tree_md.Diagnostic.render ~sources:["tab.md", source] diag in
  let lines = String.split_on_char '\n' rendered in
  let text_line = List.nth lines 3 in
  let marker_line = List.nth lines 4 in
  Alcotest.(check string) "text starts with margin"
    "   |         code" text_line;
  Alcotest.(check string) "marker aligns with text"
    "   | ^^^^^^^^^^^^" marker_line

let test_cjk_marker () =
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"cj.md" "日code")
  in
  let diag =
    Tree_md.Diagnostic.make TM001
      (Source_span (make_span "cj.md" 3 7)) "issue at code"
  in
  let rendered = Tree_md.Diagnostic.render ~sources:["cj.md", source] diag in
  let lines = String.split_on_char '\n' rendered in
  let marker_line = List.nth lines 4 in
  Alcotest.(check string) "marker aligned after multibyte"
    "   |  ^^^^" marker_line

let test_make_diagnostic () =
  let diag =
    Tree_md.Diagnostic.make TM001 No_location "something went wrong"
  in
  Alcotest.(check string) "diagnostic message"
    "something went wrong" diag.message;
  Alcotest.(check string) "diagnostic code TM001"
    "TM001" (Tree_md.Diagnostic.code_string diag.code)

let () =
  let open Alcotest in
  run "Diagnostic"
    [ "tm103_code", [ test_case "tm103_code" `Quick test_tm103_code ]
    ; "sort_by_path_then_byte", [ test_case "sort_by_path_then_byte" `Quick test_sort_by_path_then_byte ]
    ; "path_location_sorts_after_span", [ test_case "path_location_sorts_after_span" `Quick test_path_location_sorts_after_span ]
    ; "no_location_sorts_last", [ test_case "no_location_sorts_last" `Quick test_no_location_sorts_last ]
    ; "tab_excerpt", [ test_case "tab_excerpt" `Quick test_tab_excerpt ]
    ; "cjk_marker", [ test_case "cjk_marker" `Quick test_cjk_marker ]
    ; "make_diagnostic", [ test_case "make_diagnostic" `Quick test_make_diagnostic ]
    ]
