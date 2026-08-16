let source_from_string text =
  Result.get_ok (Tree_md.Source.of_string ~path:"test.md" text)

let parse_inlines text =
  let src = source_from_string text in
  Tree_md.Markdown.parse_inlines src text ~base_byte:0

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
    let alias_str = match a with
      | None -> "" | Some s -> Printf.sprintf " alias=%S" s in
    Printf.sprintf "WikiLink(%S%s)" t alias_str
  | Tree_md.Ir.Wiki_embed t ->
    Printf.sprintf "WikiEmbed(%S)" t
  | Tree_md.Ir.Math { tex = t; display = d } ->
    Printf.sprintf "Math(%S %b)" t d
  | Tree_md.Ir.Hard_break -> "HardBreak"
  | Tree_md.Ir.Soft_break -> "SoftBreak"

let strings_of result =
  match result with
  | Ok inlines -> List.map (fun i -> node_to_string i.Tree_md.Ir.node) inlines
  | Error diags ->
    let msgs = List.map (fun d ->
      Printf.sprintf "%s: %s"
        (Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code)
        d.Tree_md.Diagnostic.message
    ) diags in
    ["ERROR: " ^ String.concat "; " msgs]

let has_diag_code diags code =
  List.exists (fun d -> Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code = code) diags

(* ── Basic text and emphasis ── *)

let test_simple_text () =
  let result = parse_inlines "hello" in
  Alcotest.(check (list string)) "simple text"
    ["Text(\"hello\")"] (strings_of result)

let test_emphasis () =
  let result = parse_inlines "*hello*" in
  Alcotest.(check (list string)) "emphasis"
    ["Emphasis"] (strings_of result)

let test_strong () =
  let result = parse_inlines "**hello**" in
  Alcotest.(check (list string)) "strong"
    ["Strong"] (strings_of result)

let test_nested_emphasis () =
  let result = parse_inlines "***hello***" in
  match result with
  | Ok [outer] ->
    (match outer.Tree_md.Ir.node with
     | Tree_md.Ir.Emphasis [inner] ->
       (match inner.Tree_md.Ir.node with
        | Tree_md.Ir.Strong [text] ->
          Alcotest.(check string) "nested text"
            "Text(\"hello\")" (node_to_string text.Tree_md.Ir.node)
        | _ -> Alcotest.fail "expected Strong inside Emphasis")
     | _ -> Alcotest.fail "expected Emphasis")
  | Ok _ -> Alcotest.fail "expected single inline"
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("unexpected error: " ^ msgs)

(* ── Code ── *)

let test_inline_code () =
  let result = parse_inlines "`code`" in
  Alcotest.(check (list string)) "inline code"
    ["Code(\"code\")"] (strings_of result)

(* ── Links ── *)

let test_standard_link () =
  let result = parse_inlines "[label](https://example.test)" in
  Alcotest.(check (list string)) "standard link"
    ["Link(\"https://example.test\")[Text(\"label\")]"] (strings_of result)

let test_autolink () =
  let result = parse_inlines "<https://example.test>" in
  Alcotest.(check (list string)) "autolink"
    ["Link(\"https://example.test\")[Text(\"https://example.test\")]"] (strings_of result)

let test_autolink_email () =
  let result = parse_inlines "<a@example.test>" in
  Alcotest.(check (list string)) "email autolink"
    ["Link(\"mailto:a@example.test\")[Text(\"a@example.test\")]"]
    (strings_of result)

(* ── Images ── *)

let test_image () =
  let result = parse_inlines "![alt](https://example.test/img.png)" in
  Alcotest.(check (list string)) "image"
    ["Image(\"https://example.test/img.png\")[Text(\"alt\")]"]
    (strings_of result)

(* ── Wiki links ── *)

let test_wiki_link () =
  let result = parse_inlines "[[id]]" in
  Alcotest.(check (list string)) "wiki link"
    ["WikiLink(\"id\")"] (strings_of result)

let test_wiki_link_alias () =
  let result = parse_inlines "[[id|alias]]" in
  Alcotest.(check (list string)) "wiki link with alias"
    ["WikiLink(\"id\" alias=\"alias\")"] (strings_of result)

let test_wiki_embed () =
  let result = parse_inlines "![[id]]" in
  Alcotest.(check (list string)) "wiki embed"
    ["WikiEmbed(\"id\")"] (strings_of result)

(* ── Math ── *)

let test_inline_math () =
  let result = parse_inlines "$x$" in
  Alcotest.(check (list string)) "inline math"
    ["Math(\"x\" false)"] (strings_of result)

let test_display_math () =
  let result = parse_inlines "$$x$$" in
  Alcotest.(check (list string)) "display math"
    ["Math(\"x\" true)"] (strings_of result)

(* ── Breaks ── *)

let test_hard_break () =
  let result = parse_inlines "line1\\\nline2" in
  let has_hard = match result with
    | Ok inlines ->
      List.exists (fun i -> match i.Tree_md.Ir.node with
        | Tree_md.Ir.Hard_break -> true | _ -> false) inlines
    | Error _ -> false
  in
  Alcotest.(check bool) "has hard break" true has_hard

let test_soft_break () =
  let result = parse_inlines "line1\nline2" in
  let has_soft = match result with
    | Ok inlines ->
      List.exists (fun i -> match i.Tree_md.Ir.node with
        | Tree_md.Ir.Soft_break -> true | _ -> false) inlines
    | Error _ -> false
  in
  Alcotest.(check bool) "has soft break" true has_soft

(* ── Escaped delimiters ── *)

let test_escaped_asterisk () =
  let result = parse_inlines "\\*not emphasis*" in
  (* The \\* is an escaped literal *, so the whole thing is one Text node.
     The trailing * without an opener starts plain text. *)
  Alcotest.(check (list string)) "escaped asterisk"
    ["Text(\"*not emphasis*\")"] (strings_of result)

(* ── Unicode spans ── *)

let test_unicode () =
  let result = parse_inlines "日**本**語" in
  (* Should have Text + Strong containing Text + Text *)
  match result with
  | Ok [t1; strong; t2] ->
    Alcotest.(check string) "unicode break"
      "Text(\"\\230\\151\\165\")" (node_to_string t1.Tree_md.Ir.node);
    Alcotest.(check string) "unicode strong"
      "Strong" (node_to_string strong.Tree_md.Ir.node);
    Alcotest.(check string) "unicode end"
      "Text(\"\\232\\170\\158\")" (node_to_string t2.Tree_md.Ir.node)
  | Ok other ->
    Alcotest.(check (list string)) "unicode shape"
      ["Text(\"\\230\\151\\165\")"; "Strong"; "Text(\"\\232\\170\\158\")"]
      (strings_of result)
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("unexpected error: " ^ msgs)

(* ── Rejection tests ── *)

let test_raw_html_rejected () =
  let result = parse_inlines "<b>bold</b>" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "raw html TM102" true (has_diag_code diags "TM102")
  | Ok _ ->
    Alcotest.fail "expected error for raw HTML"

let test_strikethrough_rejected () =
  let result = parse_inlines "~~strike~~" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "strikethrough TM102" true (has_diag_code diags "TM102")
  | Ok _ ->
    Alcotest.fail "expected error for strikethrough"

(* ── URI validation tests ── *)

let test_uri_percent_encode_space () =
  let span = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:25) in
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Link span
    "https://example.test/a b"
  in
  match result with
  | Ok s ->
    Alcotest.(check string) "percent encode space" "https://example.test/a%20b" s
  | Error d ->
    Alcotest.fail ("expected Ok, got: " ^ d.Tree_md.Diagnostic.message)

let test_uri_mailto_accepted () =
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Link
    (Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:22))
    "mailto:a@example.test"
  in
  match result with
  | Ok _ -> ()
  | Error d ->
    Alcotest.fail ("expected Ok, got: " ^ d.Tree_md.Diagnostic.message)

let test_uri_fragment_accepted () =
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Link
    (Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:8))
    "#section"
  in
  match result with
  | Ok _ -> ()
  | Error d ->
    Alcotest.fail ("expected Ok, got: " ^ d.Tree_md.Diagnostic.message)

let test_uri_relative_accepted () =
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Link
    (Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:4))
    "note"
  in
  match result with
  | Ok _ -> ()
  | Error d ->
    Alcotest.fail ("expected Ok, got: " ^ d.Tree_md.Diagnostic.message)

let test_uri_javascript_rejected () =
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Link
    (Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:17))
    "javascript:alert(1)"
  in
  match result with
  | Error d ->
    Alcotest.(check string) "javascript TM205"
      "TM205" (Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code)
  | Ok _ ->
    Alcotest.fail "expected TM205 for javascript:"

let test_uri_data_image_rejected () =
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Image
    (Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:22))
    "data:image/png;base64,x"
  in
  match result with
  | Error d ->
    Alcotest.(check string) "data image TM205"
      "TM205" (Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code)
  | Ok _ ->
    Alcotest.fail "expected TM205 for data: image"

(* ── Metadata inline lowering ── *)

let test_metadata_lower_tags () =
  let src = source_from_string "**bold**" in
  let parse located =
    Tree_md.Markdown.parse_inlines src located.Tree_md.Metadata.value
      ~base_byte:located.Tree_md.Metadata.span.Tree_md.Span.start_byte
  in
  let raw : Tree_md.Metadata.raw = {
    Tree_md.Metadata.id = None;
    date = None;
    taxon = None;
    authors = [];
    contributors = [];
    tags = [
      { Tree_md.Metadata.value = "**bold**";
        span = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:10 ~end_byte:18) };
      { Tree_md.Metadata.value = "_italic_";
        span = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:20 ~end_byte:28) };
    ];
    meta = [];
  } in
  match Tree_md.Metadata.lower_inline_values ~parse raw with
  | Ok lowered ->
    Alcotest.(check int) "two tags" 2 (List.length lowered.tags);
    (match lowered.tags with
     | [tag1; tag2] ->
       (match tag1.Tree_md.Metadata.value with
        | [i] ->
          Alcotest.(check string) "tag1 bold"
            "Strong" (node_to_string i.Tree_md.Ir.node)
        | _ -> Alcotest.fail "expected one inline in tag1");
       (match tag2.Tree_md.Metadata.value with
        | [i] ->
          Alcotest.(check string) "tag2 italic"
            "Emphasis" (node_to_string i.Tree_md.Ir.node)
        | _ -> Alcotest.fail "expected one inline in tag2")
     | _ -> Alcotest.fail "expected two tags")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_metadata_lower_meta () =
  let src = source_from_string "[link](https://example.test)" in
  let parse located =
    Tree_md.Markdown.parse_inlines src located.Tree_md.Metadata.value
      ~base_byte:located.Tree_md.Metadata.span.Tree_md.Span.start_byte
  in
  let raw : Tree_md.Metadata.raw = {
    Tree_md.Metadata.id = None;
    date = None;
    taxon = None;
    authors = [];
    contributors = [];
    tags = [];
    meta = [
      ({ Tree_md.Metadata.value = "inst";
         span = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:5 ~end_byte:10) },
       { Tree_md.Metadata.value = "[link](https://example.test)";
         span = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:12 ~end_byte:40) });
    ];
  } in
  match Tree_md.Metadata.lower_inline_values ~parse raw with
  | Ok lowered ->
    Alcotest.(check int) "one meta" 1 (List.length lowered.meta);
    (match lowered.meta with
     | [(key, value)] ->
       Alcotest.(check string) "meta key" "inst" key.Tree_md.Metadata.value;
       (match value.Tree_md.Metadata.value with
        | [i] ->
          Alcotest.(check string) "meta value link"
            "Link(\"https://example.test\")[Text(\"link\")]"
            (node_to_string i.Tree_md.Ir.node)
        | _ -> Alcotest.fail "expected one inline in meta value")
     | _ -> Alcotest.fail "expected one meta entry")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Hostile Unicode / punctuation in inlines ── *)

let test_hostile_unicode () =
  let result = parse_inlines "`\\x00`" in
  match result with
  | Ok [i] ->
    (match i.Tree_md.Ir.node with
     | Tree_md.Ir.Code "\\x00" -> ()
     | _ -> Alcotest.fail "expected Code node")
  | _ -> Alcotest.fail "expected Ok"

let test_uri_nul_rejected () =
  let result = Tree_md.Safe_uri.validate Tree_md.Safe_uri.Link
    (Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:10))
    "http://a\x00b"
  in
  match result with
  | Error d ->
    Alcotest.(check string) "NUL TM205"
      "TM205" (Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code)
  | Ok _ -> Alcotest.fail "expected TM205 for NUL in URI"

(* ── Span assertions: every inline has a valid span ── *)

let test_every_inline_has_span () =
  let result = parse_inlines "hello **world**" in
  match result with
  | Ok inlines ->
    List.iter (fun (i : Tree_md.Ir.inline) ->
      let sp = i.Tree_md.Ir.span in
      Alcotest.(check bool) "span start_byte >= 0"
        true (sp.Tree_md.Span.start_byte >= 0);
      Alcotest.(check bool) "span end_byte >= start_byte"
        true (sp.Tree_md.Span.end_byte >= sp.Tree_md.Span.start_byte)
    ) inlines
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Nested emphasis in link text ── *)

let test_link_with_emphasis () =
  let result = parse_inlines "[**bold** link](https://example.test)" in
  Alcotest.(check (list string)) "link with emphasis"
    ["Link(\"https://example.test\")[Strong Text(\" link\")]"]
    (strings_of result)

(* ── Image with title ── *)

let test_image_with_title () =
  let result = parse_inlines "![alt](https://example.test/img.png \"title\")" in
  Alcotest.(check (list string)) "image with title"
    ["Image(\"https://example.test/img.png\")[Text(\"alt\")]"]
    (strings_of result)

(* ── Integration: javascript data URI via parse_inlines ── *)

let test_parse_link_javascript_rejected () =
  let result = parse_inlines "[label](javascript:alert(1))" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "javascript link TM205 via parse" true (has_diag_code diags "TM205")
  | Ok _ -> Alcotest.fail "expected TM205 for javascript: link"

let test_parse_image_data_rejected () =
  let result = parse_inlines "![alt](data:image/png;base64,x)" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "data image TM205 via parse" true (has_diag_code diags "TM205")
  | Ok _ -> Alcotest.fail "expected TM205 for data: image"

(* ── Invalid Wiki forms via parse_inlines ── *)

let test_parse_wiki_bad_id () =
  let result = parse_inlines "[[bad id]]" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "bad wiki id TM105" true (has_diag_code diags "TM105")
  | Ok _ -> Alcotest.fail "expected TM105 for invalid wiki target"

let test_parse_wiki_empty_alias () =
  let result = parse_inlines "[[id|]]" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "empty alias TM105" true (has_diag_code diags "TM105")
  | Ok _ -> Alcotest.fail "expected TM105 for empty alias"

let test_parse_wiki_multi_pipe () =
  let result = parse_inlines "[[id|a|b]]" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "multi pipe TM105" true (has_diag_code diags "TM105")
  | Ok _ -> Alcotest.fail "expected TM105 for multiple pipes"

(* ── Invalid math forms via parse_inlines ── *)

let test_parse_empty_math () =
  let result = parse_inlines "$$ $$" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "empty math TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for empty math"

let test_parse_unbalanced_math () =
  let result = parse_inlines "${a{b$" in
  match result with
  | Error diags ->
    Alcotest.(check bool) "unbalanced math TM107" true (has_diag_code diags "TM107")
  | Ok _ -> Alcotest.fail "expected TM107 for unbalanced braces"

(* ── Percent encoding applied via parse_inlines ── *)

let test_parse_link_space_encoded () =
  let result = parse_inlines "[label](<https://example.test/a b>)" in
  match result with
  | Ok inlines ->
    (match inlines with
     | [{ Tree_md.Ir.node = Tree_md.Ir.Link { destination = dest; _ }; _ }] ->
       Alcotest.(check string) "link space encoded" "https://example.test/a%20b" dest
     | _ -> Alcotest.fail "expected Link node")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_parse_link_fragment_encoded () =
  let result = parse_inlines "[label](#section)" in
  match result with
  | Ok inlines ->
    (match inlines with
     | [{ Tree_md.Ir.node = Tree_md.Ir.Link { destination = dest; _ }; _ }] ->
       Alcotest.(check string) "fragment preserved" "#section" dest
     | _ -> Alcotest.fail "expected Link node")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

let test_parse_link_relative_encoded () =
  let result = parse_inlines "[label](note)" in
  match result with
  | Ok inlines ->
    (match inlines with
     | [{ Tree_md.Ir.node = Tree_md.Ir.Link { destination = dest; _ }; _ }] ->
       Alcotest.(check string) "relative preserved" "note" dest
     | _ -> Alcotest.fail "expected Link node")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── math span assertions ── *)

let test_parse_math_has_span () =
  let result = parse_inlines "$x$" in
  match result with
  | Ok [i] ->
    Alcotest.(check bool) "math span valid" true
      (i.Tree_md.Ir.span.Tree_md.Span.end_byte > i.Tree_md.Ir.span.Tree_md.Span.start_byte)
  | _ -> Alcotest.fail "expected Ok"

let () =
  let open Alcotest in
  run "Inline"
    [ "simple_text", [ test_case "simple_text" `Quick test_simple_text ]
    ; "emphasis", [ test_case "emphasis" `Quick test_emphasis ]
    ; "strong", [ test_case "strong" `Quick test_strong ]
    ; "nested_emphasis", [ test_case "nested_emphasis" `Quick test_nested_emphasis ]
    ; "inline_code", [ test_case "inline_code" `Quick test_inline_code ]
    ; "standard_link", [ test_case "standard_link" `Quick test_standard_link ]
    ; "autolink", [ test_case "autolink" `Quick test_autolink ]
    ; "autolink_email", [ test_case "autolink_email" `Quick test_autolink_email ]
    ; "image", [ test_case "image" `Quick test_image ]
    ; "wiki_link", [ test_case "wiki_link" `Quick test_wiki_link ]
    ; "wiki_link_alias", [ test_case "wiki_link_alias" `Quick test_wiki_link_alias ]
    ; "wiki_embed", [ test_case "wiki_embed" `Quick test_wiki_embed ]
    ; "inline_math", [ test_case "inline_math" `Quick test_inline_math ]
    ; "display_math", [ test_case "display_math" `Quick test_display_math ]
    ; "hard_break", [ test_case "hard_break" `Quick test_hard_break ]
    ; "soft_break", [ test_case "soft_break" `Quick test_soft_break ]
    ; "escaped_asterisk", [ test_case "escaped_asterisk" `Quick test_escaped_asterisk ]
    ; "unicode", [ test_case "unicode" `Quick test_unicode ]
    ; "raw_html_rejected", [ test_case "raw_html_rejected" `Quick test_raw_html_rejected ]
    ; "strikethrough_rejected", [ test_case "strikethrough_rejected" `Quick test_strikethrough_rejected ]
    ; "uri_percent_encode_space", [ test_case "uri_percent_encode_space" `Quick test_uri_percent_encode_space ]
    ; "uri_mailto_accepted", [ test_case "uri_mailto_accepted" `Quick test_uri_mailto_accepted ]
    ; "uri_fragment_accepted", [ test_case "uri_fragment_accepted" `Quick test_uri_fragment_accepted ]
    ; "uri_relative_accepted", [ test_case "uri_relative_accepted" `Quick test_uri_relative_accepted ]
    ; "uri_javascript_rejected", [ test_case "uri_javascript_rejected" `Quick test_uri_javascript_rejected ]
    ; "uri_data_image_rejected", [ test_case "uri_data_image_rejected" `Quick test_uri_data_image_rejected ]
    ; "metadata_lower_tags", [ test_case "metadata_lower_tags" `Quick test_metadata_lower_tags ]
    ; "metadata_lower_meta", [ test_case "metadata_lower_meta" `Quick test_metadata_lower_meta ]
    ; "hostile_unicode", [ test_case "hostile_unicode" `Quick test_hostile_unicode ]
    ; "uri_nul_rejected", [ test_case "uri_nul_rejected" `Quick test_uri_nul_rejected ]
    ; "every_inline_has_span", [ test_case "every_inline_has_span" `Quick test_every_inline_has_span ]
    ; "link_with_emphasis", [ test_case "link_with_emphasis" `Quick test_link_with_emphasis ]
    ; "image_with_title", [ test_case "image_with_title" `Quick test_image_with_title ]
    ; "parse_link_javascript_rejected", [ test_case "parse_link_javascript_rejected" `Quick test_parse_link_javascript_rejected ]
    ; "parse_image_data_rejected", [ test_case "parse_image_data_rejected" `Quick test_parse_image_data_rejected ]
    ; "parse_wiki_bad_id", [ test_case "parse_wiki_bad_id" `Quick test_parse_wiki_bad_id ]
    ; "parse_wiki_empty_alias", [ test_case "parse_wiki_empty_alias" `Quick test_parse_wiki_empty_alias ]
    ; "parse_wiki_multi_pipe", [ test_case "parse_wiki_multi_pipe" `Quick test_parse_wiki_multi_pipe ]
    ; "parse_empty_math", [ test_case "parse_empty_math" `Quick test_parse_empty_math ]
    ; "parse_unbalanced_math", [ test_case "parse_unbalanced_math" `Quick test_parse_unbalanced_math ]
    ; "parse_link_space_encoded", [ test_case "parse_link_space_encoded" `Quick test_parse_link_space_encoded ]
    ; "parse_link_fragment_encoded", [ test_case "parse_link_fragment_encoded" `Quick test_parse_link_fragment_encoded ]
    ; "parse_link_relative_encoded", [ test_case "parse_link_relative_encoded" `Quick test_parse_link_relative_encoded ]
    ; "parse_math_has_span", [ test_case "parse_math_has_span" `Quick test_parse_math_has_span ]
    ]
