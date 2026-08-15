let test_utf8_and_locations () =
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"note.tree.md" "a\r\n日\tb")
  in
  Alcotest.(check (pair int int)) "Japanese starts line 2 column 1"
    (2, 1) (Result.get_ok (Tree_md.Source.line_col source ~byte:3));
  Alcotest.(check int) "character index maps to byte"
    3 (Option.get (Tree_md.Source.character_to_byte source ~character:3));
  Alcotest.(check int) "byte length" 8 (Tree_md.Source.length source)

let test_invalid_utf8 () =
  match Tree_md.Source.of_string ~path:"bad.tree.md" "\xFF" with
  | Error { byte = 0 } -> ()
  | _ -> Alcotest.fail "expected invalid UTF-8 at byte 0"

let test_slice () =
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"test.md" "hello world")
  in
  let span = Result.get_ok (Tree_md.Source.span source ~start_byte:0 ~end_byte:5) in
  Alcotest.(check string) "slice" "hello" (Result.get_ok (Tree_md.Source.slice source span))

let test_span_make () =
  let _ = Result.get_ok (Tree_md.Span.make ~path:"f.md" ~start_byte:0 ~end_byte:1) in
  match Tree_md.Span.make ~path:"f.md" ~start_byte:(-1) ~end_byte:0 with
  | Error msg ->
    Alcotest.(check string) "negative start byte" "start byte is negative" msg
  | Ok _ -> Alcotest.fail "expected error for negative start_byte"

let () =
  let open Alcotest in
  run "Source"
    [ "utf8_and_locations", [ test_case "utf8_and_locations" `Quick test_utf8_and_locations ]
    ; "invalid_utf8", [ test_case "invalid_utf8" `Quick test_invalid_utf8 ]
    ; "slice", [ test_case "slice" `Quick test_slice ]
    ; "span_make", [ test_case "span_make" `Quick test_span_make ]
    ]
