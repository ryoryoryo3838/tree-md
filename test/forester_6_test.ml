open Tree_md

(* ── Test helpers ── *)

let string_contains s sub =
  let len = String.length s in
  let sublen = String.length sub in
  if sublen > len then false
  else
    let rec loop i =
      if i > len - sublen then false
      else if String.sub s i sublen = sub then true
      else loop (i + 1)
    in
    loop 0

let string_index s sub =
  let len = String.length s in
  let sublen = String.length sub in
  if sublen > len then raise Not_found
  else
    let rec loop i =
      if i > len - sublen then raise Not_found
      else if String.sub s i sublen = sub then i
      else loop (i + 1)
    in
    loop 0

let zero_span =
  match Span.make ~path:"test.md" ~start_byte:0 ~end_byte:0 with
  | Ok s -> s | Error _ -> failwith "cannot create span"

let text_inline s = { Ir.node = Ir.Text s; Ir.span = zero_span }
let emph inlines = { Ir.node = Ir.Emphasis inlines; Ir.span = zero_span }
let strong inlines = { Ir.node = Ir.Strong inlines; Ir.span = zero_span }
let code_inline s = { Ir.node = Ir.Code s; Ir.span = zero_span }
let hard_break () = { Ir.node = Ir.Hard_break; Ir.span = zero_span }
let soft_break () = { Ir.node = Ir.Soft_break; Ir.span = zero_span }
let math_inline tex display = { Ir.node = Ir.Math { tex; display }; Ir.span = zero_span }
let wiki_link target alias = { Ir.node = Ir.Wiki_link { target; alias }; Ir.span = zero_span }
let wiki_embed target = { Ir.node = Ir.Wiki_embed target; Ir.span = zero_span }

let external_link label dest title =
  { Ir.node = Ir.Link { label; destination = dest; title }; Ir.span = zero_span }

let external_image alt dest title =
  { Ir.node = Ir.Image { alt; destination = dest; asset_path = dest; width = None; title };
    Ir.span = zero_span }

let local_image alt dest span =
  { Ir.node = Ir.Image { alt; destination = dest; asset_path = dest; width = None; title = None };
    Ir.span = span }

let para inlines = { Ir.bnode = Ir.Paragraph inlines; Ir.bspan = zero_span }
let blockquote blocks = { Ir.bnode = Ir.Blockquote blocks; Ir.bspan = zero_span }
let code_block info code = { Ir.bnode = Ir.Code_block { info; code }; Ir.bspan = zero_span }
let thematic () = { Ir.bnode = Ir.Thematic_break; Ir.bspan = zero_span }
let block_embed id = { Ir.bnode = Ir.Block_embed id; Ir.bspan = zero_span }
let display_math tex = { Ir.bnode = Ir.Display_math tex; Ir.bspan = zero_span }

let heading level title =
  { Ir.bnode = Ir.Heading { level; title }; Ir.bspan = zero_span }

let ordered_list ?(tight=true) start items : Ir.block =
  { Ir.bnode = Ir.List { kind = Ir.Ordered start; tight; items }; Ir.bspan = zero_span }

let unordered_list ?(tight=true) items : Ir.block =
  { Ir.bnode = Ir.List { kind = Ir.Unordered; tight; items }; Ir.bspan = zero_span }

let list_item ?item_task blocks : Ir.list_item =
  { Ir.item_blocks = blocks; Ir.item_task; Ir.item_span = zero_span }

let li_text s = list_item [para [text_inline s]]
let li_paras inlines_list = list_item (List.map (fun is -> para is) inlines_list)

let empty_meta : Ir.inline list Metadata.t =
  { Metadata.date = None; Metadata.taxon = None;
    Metadata.authors = []; Metadata.contributors = [];
    Metadata.tags = []; Metadata.meta = [] }

let doc ?(metadata=empty_meta) blocks =
  { Ir.metadata = metadata; Ir.blocks = blocks; Ir.doc_span = zero_span }

let outline ?(root_id="test") d =
  match Outline.build ~root_id ~filename:root_id d with
  | Ok (t, _) -> t
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    failwith ("Outline.build failed: " ^ msgs)

let outline_blocks root_id blocks =
  outline ~root_id (doc blocks)

let emit_str ?(resolution=Resolution.empty) (t : Outline.t) =
  match Forester_6.emit ~resolution t with
  | Ok (s, _) -> s
  | Error diags ->
    let msgs = List.map (fun d ->
      Printf.sprintf "%s: %s" (Diagnostic.code_string d.Diagnostic.code) d.Diagnostic.message
    ) diags |> String.concat "; " in
    failwith ("emit failed: " ^ msgs)

let emit_err ?(resolution=Resolution.empty) (t : Outline.t) =
  match Forester_6.emit ~resolution t with
  | Ok (s, _) -> failwith ("expected error, got: " ^ s)
  | Error diags -> diags

let lines s =
  String.split_on_char '\n' s

(* ── Untitled subtrees and interleaved content ── *)

let open_dir ?id level =
  { Ir.bnode = Ir.Subtree_open { level; id }; Ir.bspan = zero_span }
let close_dir level = { Ir.bnode = Ir.Subtree_close level; Ir.bspan = zero_span }

(* Forester allows a subtree with no \title; a Markdown heading cannot express
   one, so it is what the <!-- hN --> directive exists for. *)
let test_untitled_subtree_omits_title () =
  Alcotest.(check string) "no title command"
    "\\title{Root}\n\\subtree{\n\\p{body}\n}\n"
    (emit_str (outline_blocks "t"
       [heading 1 [text_inline "Root"]; open_dir 2; para [text_inline "body"]]))

let test_untitled_subtree_keeps_id () =
  Alcotest.(check string) "id without title"
    "\\title{Root}\n\\subtree[sec]{\n\\p{body}\n}\n"
    (emit_str (outline_blocks "t"
       [heading 1 [text_inline "Root"]; open_dir ~id:"sec" 2; para [text_inline "body"]]))

(* The block after the closing directive must be emitted after the subtree, not
   hoisted above it. *)
let test_block_after_subtree_keeps_order () =
  Alcotest.(check string) "order preserved"
    "\\title{Root}\n\\subtree{\n\\p{inside}\n}\n\n\\p{outside}\n"
    (emit_str (outline_blocks "t"
       [heading 1 [text_inline "Root"]; open_dir 2; para [text_inline "inside"];
        close_dir 2; para [text_inline "outside"]]))

let test_nested_untitled_subtree () =
  Alcotest.(check string) "nested"
    "\\title{Root}\n\\subtree{\n\\p{a}\n\n\\subtree{\n\\p{b}\n}\n}\n"
    (emit_str (outline_blocks "t"
       [heading 1 [text_inline "Root"]; open_dir 2; para [text_inline "a"];
        open_dir 3; para [text_inline "b"]]))

(* ── Target string ── *)

let test_target_string () =
  Alcotest.(check string) "target"
    "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"
    Forester_6.target

(* ── Escaping tests ── *)

let test_escape_percent () =
  let expected = "\\" ^ "%" in
  Alcotest.(check string) "percent" expected
    (Forester_6.escape_text_for_test "%")

let test_escape_backslash () =
  Alcotest.(check string) "backslash" "\\verbFMD|\\FMD"
    (Forester_6.escape_text_for_test "\\")

let test_escape_hash () =
  Alcotest.(check string) "hash" "\\verbFMD|#FMD"
    (Forester_6.escape_text_for_test "#")

let test_escape_lbrace () =
  Alcotest.(check string) "lbrace" "\\verbFMD|{FMD"
    (Forester_6.escape_text_for_test "{")

let test_escape_rbrace () =
  Alcotest.(check string) "rbrace" "\\verbFMD|}FMD"
    (Forester_6.escape_text_for_test "}")

let test_escape_lbracket () =
  Alcotest.(check string) "lbracket" "\\verbFMD|[FMD"
    (Forester_6.escape_text_for_test "[")

let test_escape_rbracket () =
  Alcotest.(check string) "rbracket" "\\verbFMD|]FMD"
    (Forester_6.escape_text_for_test "]")

let test_escape_lparen () =
  Alcotest.(check string) "lparen" "\\verbFMD|(FMD"
    (Forester_6.escape_text_for_test "(")

let test_escape_rparen () =
  Alcotest.(check string) "rparen" "\\verbFMD|)FMD"
    (Forester_6.escape_text_for_test ")")

let test_escape_unchanged () =
  Alcotest.(check string) "unchanged" "<>&日本"
    (Forester_6.escape_text_for_test "<>&日本")

let test_escape_mixed () =
  let pct = "\\" ^ "%" in
  let expected = pct ^ " verb\\verbFMD|\\FMD" in
  Alcotest.(check string) "mixed" expected
    (Forester_6.escape_text_for_test "% verb\\")

let test_escape_full_string () =
  let result = Forester_6.escape_text_for_test "hello{w}orld" in
  let expected = "hello\\verbFMD|{FMDw\\verbFMD|}FMDorld" in
  Alcotest.(check string) "full string escape" expected result

(* ── Simple emission tests ── *)

let test_simple_paragraph () =
  let t = outline_blocks "test" [para [text_inline "hello"]] in
  Alcotest.(check string) "simple paragraph"
    "\\title{test}\n\\p{hello}\n"
    (emit_str t)

let test_empty_body () =
  let t = outline_blocks "test" [] in
  Alcotest.(check string) "empty body"
    "\\title{test}\n"
    (emit_str t)

(* ── Inline formatting tests ── *)

let test_emphasis_emission () =
  let t = outline_blocks "test" [para [emph [text_inline "hello"]]] in
  Alcotest.(check string) "emphasis"
    "\\title{test}\n\\p{\\em{hello}}\n"
    (emit_str t)

let test_strong_emission () =
  let t = outline_blocks "test" [para [strong [text_inline "hello"]]] in
  Alcotest.(check string) "strong"
    "\\title{test}\n\\p{\\strong{hello}}\n"
    (emit_str t)

let test_inline_code_emission () =
  let t = outline_blocks "test" [para [code_inline "x := 1"]] in
  Alcotest.(check string) "inline code"
    "\\title{test}\n\\p{\\code{x := 1}}\n"
    (emit_str t)

let test_hard_break_emission () =
  let t = outline_blocks "test" [para [text_inline "a"; hard_break (); text_inline "b"]] in
  Alcotest.(check string) "hard break"
    "\\title{test}\n\\p{a\\<html:br>{}b}\n"
    (emit_str t)

let test_soft_break_emission () =
  let t = outline_blocks "test" [para [text_inline "a"; soft_break (); text_inline "b"]] in
  Alcotest.(check string) "soft break"
    "\\title{test}\n\\p{a b}\n"
    (emit_str t)

(* ── Math tests (approved #{} and ##{} forms) ── *)

let test_inline_math_emission () =
  let t = outline_blocks "test" [para [math_inline "x^2" false]] in
  Alcotest.(check string) "inline math"
    "\\title{test}\n\\p{#{x^2}}\n"
    (emit_str t)

let test_display_math_inline_emission () =
  let t = outline_blocks "test" [para [math_inline "x^2" true]] in
  Alcotest.(check string) "display math inline"
    "\\title{test}\n\\p{#{x^2}}\n"
    (emit_str t)

let test_display_math_block_emission () =
  let t = outline_blocks "test" [display_math "x^2"] in
  Alcotest.(check string) "display math block"
    "\\title{test}\n##{x^2}\n"
    (emit_str t)

(* ── Links tests (native forms) ── *)

let test_external_link_emission () =
  let t = outline_blocks "test"
    [para [external_link [text_inline "click"] "https://example.test" None]] in
  Alcotest.(check string) "external link"
    "\\title{test}\n\\p{[click](https://example.test)}\n"
    (emit_str t)

let test_http_link_emission () =
  let t = outline_blocks "test"
    [para [external_link [text_inline "click"] "http://example.test" None]] in
  Alcotest.(check string) "http link"
    "\\title{test}\n\\p{[click](http://example.test)}\n"
    (emit_str t)

let test_external_link_with_title () =
  let t = outline_blocks "test"
    [para [external_link [text_inline "click"] "https://example.test" (Some "tooltip")]] in
  Alcotest.(check string) "external link with title"
    "\\title{test}\n\\p{\\<html:a>[href]{https://example.test}[title]{tooltip}{click}}\n"
    (emit_str t)

let test_wiki_link_emission () =
  let t = outline_blocks "test" [para [wiki_link "my.tree" None]] in
  Alcotest.(check string) "wiki link"
    "\\title{test}\n\\p{[[my.tree]]}\n"
    (emit_str t)

let test_wiki_link_alias_emission () =
  let t = outline_blocks "test" [para [wiki_link "my.tree" (Some "display")]] in
  Alcotest.(check string) "wiki link alias"
    "\\title{test}\n\\p{[display](my.tree)}\n"
    (emit_str t)

let test_wiki_embed_emission () =
  let t = outline_blocks "test" [para [wiki_embed "my.tree"]] in
  Alcotest.(check string) "wiki embed inline"
    "\\title{test}\n\\p{\\transclude{my.tree}}\n"
    (emit_str t)

(* When the forest index maps a written spelling onto a different identity, the
   emitted tree names the identity. *)
let test_resolved_reference_uses_identity () =
  let resolution = Resolution.add_tree zero_span ~id:"beta" Resolution.empty in
  let t =
    outline_blocks "test"
      [ para [wiki_link "beta.tree" None];
        para [wiki_embed "beta.tree"];
        block_embed "beta.tree" ]
  in
  let out = emit_str ~resolution t in
  Alcotest.(check bool) "wiki link uses the identity" true
    (string_contains out "[[beta]]");
  Alcotest.(check bool) "inline transclude uses the identity" true
    (string_contains out "\\p{\\transclude{beta}}");
  Alcotest.(check bool) "block transclude uses the identity" true
    (string_contains out "\\transclude{beta}");
  Alcotest.(check bool) "written spelling is not emitted" false
    (string_contains out "beta.tree")

(* ── Image tests ── *)

let test_external_image_emission () =
  let t = outline_blocks "test"
    [para [external_image [text_inline "alt"] "https://example.test/img.png" None]] in
  Alcotest.(check string) "external image"
    "\\title{test}\n\\p{\\<html:img>[src]{https://example.test/img.png}[alt]{alt}{}}\n"
    (emit_str t)

let test_http_image_emission () =
  let t = outline_blocks "test"
    [para [external_image [text_inline "alt"] "http://example.test/img.png" None]] in
  Alcotest.(check string) "http image"
    "\\title{test}\n\\p{\\<html:img>[src]{http://example.test/img.png}[alt]{alt}{}}\n"
    (emit_str t)

let test_local_image_with_resolution () =
  let img_span =
    match Span.make ~path:"test.md" ~start_byte:10 ~end_byte:30 with
    | Ok s -> s | Error _ -> failwith "span"
  in
  let t = outline_blocks "test" [para [local_image [text_inline "photo"] "assets/cat.png" img_span]] in
  let resolution = Resolution.add_asset img_span ~routed_path:"root/assets/cat.png" Resolution.empty in
  Alcotest.(check bool) "local image routed has route-asset"
    true (string_contains (emit_str ~resolution t) "\\route-asset{root/assets/cat.png}")

let test_local_image_no_resolution_error () =
  let img_span =
    match Span.make ~path:"test.md" ~start_byte:50 ~end_byte:70 with
    | Ok s -> s | Error _ -> failwith "span"
  in
  let t = outline_blocks "test" [para [local_image [text_inline "x"] "nope.png" img_span]] in
  let diags = emit_err ~resolution:Resolution.empty t in
  Alcotest.(check bool) "TM106 for unresolved local image"
    true (List.exists (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM106") diags)

(* ── Block tests ── *)

let test_blockquote_emission () =
  let t = outline_blocks "test" [blockquote [para [text_inline "quoted"]]] in
  Alcotest.(check string) "blockquote"
    "\\title{test}\n\\blockquote{\\p{quoted}}\n"
    (emit_str t)

let test_thematic_break_emission () =
  let t = outline_blocks "test" [thematic ()] in
  Alcotest.(check string) "thematic break"
    "\\title{test}\n\\<html:hr>{}\n"
    (emit_str t)

let test_code_block_no_lang () =
  let t = outline_blocks "test" [code_block Ir.No_info "x := 1"] in
  Alcotest.(check string) "code block no language"
    "\\title{test}\n\\<html:pre>{\\<html:code>{x := 1}}\n"
    (emit_str t)

let test_code_block_with_lang () =
  let t = outline_blocks "test" [code_block (Ir.Language "ocaml") "let x = 1"] in
  Alcotest.(check string) "code block with language"
    "\\title{test}\n\\<html:pre>[class]{language-ocaml}{\\<html:code>{let x = 1}}\n"
    (emit_str t)

let test_block_embed_emission () =
  let t = outline_blocks "test" [block_embed "other.tree"] in
  Alcotest.(check string) "block embed"
    "\\title{test}\n\\transclude{other.tree}\n"
    (emit_str t)

(* ── Hostile code tests ── *)

let test_hostile_inline_code () =
  let t = outline_blocks "test" [para [code_inline "{a}"]] in
  let result = emit_str t in
  Alcotest.(check bool) "inline code lbrace escaped"
    true (string_contains result "\\verbFMD|{FMD");
  Alcotest.(check bool) "inline code rbrace escaped"
    true (string_contains result "\\verbFMD|}FMD")

let test_hostile_code_block_content () =
  let t = outline_blocks "test" [code_block Ir.No_info "line{n}"] in
  let result = emit_str t in
  Alcotest.(check bool) "code block lbrace escaped"
    true (string_contains result "\\verbFMD|{FMD")

(* ── Multi-line code block ── *)

let test_code_block_multiline () =
  let t = outline_blocks "test" [code_block Ir.No_info "line1\nline2\n\\backslash"] in
  let result = emit_str t in
  Alcotest.(check bool) "multi-line code contains newline"
    true (String.contains result '\n');
  Alcotest.(check bool) "code keeps backslash"
    true (String.contains result '\\')

(* ── List tests (\\ul/\\ol wrappers) ── *)

let test_tight_unordered_list () =
  let t = outline_blocks "test"
    [unordered_list ~tight:true [li_text "a"; li_text "b"]] in
  Alcotest.(check string) "tight unordered list"
    "\\title{test}\n\\ul{\\li{a}\n\\li{b}}\n"
    (emit_str t)

let test_loose_unordered_list () =
  let t = outline_blocks "test"
    [unordered_list ~tight:false [li_text "a"; li_text "b"]] in
  Alcotest.(check string) "loose unordered list"
    "\\title{test}\n\\ul{\\li{\\p{a}}\n\\li{\\p{b}}}\n"
    (emit_str t)

let test_tight_ordered_list_start_1 () =
  let t = outline_blocks "test"
    [ordered_list ~tight:true 1 [li_text "first"; li_text "second"]] in
  Alcotest.(check string) "tight ordered list start 1"
    "\\title{test}\n\\ol{\\li{first}\n\\li{second}}\n"
    (emit_str t)

let test_ordered_list_start_7 () =
  let t = outline_blocks "test"
    [ordered_list ~tight:true 7 [li_text "seven"; li_text "eight"]] in
  Alcotest.(check string) "ordered list start 7"
    "\\title{test}\n\\<html:ol>[start]{7}{\\li{seven}\\li{eight}}\n"
    (emit_str t)

let test_loose_ordered_list_start_3 () =
  let t = outline_blocks "test"
    [ordered_list ~tight:false 3 [li_text "three"; li_text "four"]] in
  Alcotest.(check string) "loose ordered list start 3"
    "\\title{test}\n\\<html:ol>[start]{3}{\\li{\\p{three}}\\li{\\p{four}}}\n"
    (emit_str t)

(* ── Multiple blocks with blank lines ── *)

let test_multiple_blocks_separated () =
  let t = outline_blocks "test"
    [para [text_inline "first"]; para [text_inline "second"]] in
  let result = emit_str t in
  let ls = lines result in
  let blank_idx = ref None in
  List.iteri (fun i line ->
    if line = "" then blank_idx := Some i
  ) ls;
  Alcotest.(check bool) "blank line between blocks" true (!blank_idx <> None)

let test_final_newline () =
  let t = outline_blocks "test" [para [text_inline "x"]] in
  let result = emit_str t in
  Alcotest.(check bool) "final newline"
    true (String.length result > 0 && result.[String.length result - 1] = '\n')

(* ── UTF-8 emission ── *)

let test_utf8_text () =
  let t = outline_blocks "test" [para [text_inline "日本語テスト"]] in
  Alcotest.(check string) "utf8 text"
    "\\title{test}\n\\p{日本語テスト}\n"
    (emit_str t)

(* ── Metadata tests ── *)

let test_metadata_date () =
  let meta = { empty_meta with Metadata.date = Some
    { Metadata.value = "2024-01-01";
      span = zero_span }
  } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata date"
    true (string_contains result "\\date{2024-01-01}")

let test_metadata_taxon () =
  let meta = { empty_meta with Metadata.taxon = Some
    { Metadata.value = "article";
      span = zero_span }
  } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata taxon"
    true (string_contains result "\\taxon{article}")

let test_metadata_authors_literal () =
  let meta = { empty_meta with Metadata.authors = [
    Metadata.Literal { Metadata.value = "Alice"; span = zero_span }
  ] } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata author/literal"
    true (string_contains result "\\author/literal{Alice}")

let test_metadata_authors_tree () =
  let meta = { empty_meta with Metadata.authors = [
    Metadata.Tree { Metadata.value = "alice"; span = zero_span }
  ] } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata author tree"
    true (string_contains result "\\author{alice}");
  Alcotest.(check bool) "no \\tree wrapper"
    true (not (string_contains result "\\tree{"))

let test_metadata_contributors () =
  let meta = { empty_meta with Metadata.contributors = [
    Metadata.Literal { Metadata.value = "Bob"; span = zero_span }
  ] } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata contributor/literal"
    true (string_contains result "\\contributor/literal{Bob}")

let test_metadata_tags () =
  let meta = { empty_meta with Metadata.tags = [
    { Metadata.value = [text_inline "ocaml"]; span = zero_span }
  ] } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata tag"
    true (string_contains result "\\tag{ocaml}")

let test_metadata_meta () =
  let meta = { empty_meta with Metadata.meta = [
    ({ Metadata.value = "key"; span = zero_span },
     { Metadata.value = [text_inline "val"]; span = zero_span })
  ] } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  Alcotest.(check bool) "metadata meta"
    true (string_contains result "\\meta{key}{val}")

let test_metadata_order () =
  let meta = {
    Metadata.date = Some { value = "2024-01-01"; span = zero_span };
    taxon = Some { value = "article"; span = zero_span };
    authors = [Metadata.Literal { value = "Alice"; span = zero_span }];
    contributors = [Metadata.Literal { value = "Bob"; span = zero_span }];
    tags = [{ value = [text_inline "ocaml"]; span = zero_span }];
    meta = [({ value = "inst"; span = zero_span },
             { value = [text_inline "MIT"]; span = zero_span })];
  } in
  let t = outline (doc ~metadata:meta [para [text_inline "body"]]) in
  let result = emit_str t in
  let date_idx = try string_index result "\\date" with Not_found -> max_int in
  let taxon_idx = try string_index result "\\taxon" with Not_found -> max_int in
  let author_idx = try string_index result "\\author" with Not_found -> max_int in
  let contrib_idx = try string_index result "\\contributor" with Not_found -> max_int in
  let tag_idx = try string_index result "\\tag" with Not_found -> max_int in
  let meta_idx = try string_index result "\\meta" with Not_found -> max_int in
  Alcotest.(check bool) "date before taxon" true (date_idx < taxon_idx);
  Alcotest.(check bool) "taxon before author" true (taxon_idx < author_idx);
  Alcotest.(check bool) "author before contributor" true (author_idx < contrib_idx);
  Alcotest.(check bool) "contributor before tag" true (contrib_idx < tag_idx);
  Alcotest.(check bool) "tag before meta" true (tag_idx < meta_idx)

(* ── Section tests (\\subtree form) ── *)

let test_named_and_anon_sections () =
  let t = outline (doc [
    heading 1 [text_inline "Root"];
    { Ir.bnode = Ir.Subtree_directive "my.id"; Ir.bspan = zero_span };
    heading 2 [text_inline "Named"];
    para [text_inline "named body"];
    heading 2 [text_inline "Anonymous"];
    para [text_inline "anon body"];
  ]) in
  let result = emit_str t in
  Alcotest.(check bool) "named subtree present"
    true (string_contains result "\\subtree[my.id]");
  Alcotest.(check bool) "named title in output"
    true (string_contains result "\\title{Named}");
  Alcotest.(check bool) "named body present"
    true (string_contains result "named body");
  Alcotest.(check bool) "anonymous subtree present"
    true (string_contains result "\\subtree{");
  Alcotest.(check bool) "no legacy \\section"
    true (not (string_contains result "\\section{"))

(* ── TM107 unbalanced math in emitter ── *)

let test_math_unbalanced_error () =
  let t = outline_blocks "test" [para [math_inline "x{" false]] in
  let diags = emit_err t in
  Alcotest.(check bool) "TM107 unbalanced math"
    true (List.exists (fun d -> Diagnostic.code_string d.Diagnostic.code = "TM107") diags)

let test_math_balanced_passes () =
  let t = outline_blocks "test" [para [math_inline "x{y}" false]] in
  let result = emit_str t in
  Alcotest.(check bool) "balanced math passes"
    true (string_contains result "#{x{y}}")

(* ── XML attribute safety ── *)

let test_xml_attr_escaping () =
  let t = outline_blocks "test" [code_block (Ir.Language "c++") "int x;"] in
  let result = emit_str t in
  Alcotest.(check bool) "code block lang emitted"
    true (string_contains result "language-c++")

(* ── Hostile escaping in inline text ── *)

let test_hostile_chars_in_paragraph () =
  let t = outline_blocks "test" [para [text_inline "a{b}c%d"]] in
  let result = emit_str t in
  Alcotest.(check bool) "hostile lbrace escaped"
    true (string_contains result "\\verbFMD|{FMD");
  Alcotest.(check bool) "hostile rbrace escaped"
    true (string_contains result "\\verbFMD|}FMD");
  let pct_esc = "\\" ^ "%" in
  Alcotest.(check bool) "hostile percent escaped"
    true (string_contains result pct_esc)

(* ── Multiple inlines in one paragraph ── *)

let test_mixed_inlines () =
  let t = outline_blocks "test"
    [para [text_inline "Hello "; emph [text_inline "world"]; text_inline "!"]] in
  Alcotest.(check string) "mixed inlines"
    "\\title{test}\n\\p{Hello \\em{world}!}\n"
    (emit_str t)

(* ── Image alt flattening ── *)

let test_image_alt_flattening () =
  let t = outline_blocks "test"
    [para [external_image [text_inline "see "; emph [text_inline "this"]; text_inline " pic"]
            "https://example.test/img.png" None]] in
  Alcotest.(check string) "image alt flatten"
    "\\title{test}\n\\p{\\<html:img>[src]{https://example.test/img.png}[alt]{see this pic}{}}\n"
    (emit_str t)

(* ── Resolution tests ── *)

let test_resolution_empty () =
  Alcotest.(check (option string)) "empty resolution"
    None (Resolution.asset_route Resolution.empty zero_span)

let test_resolution_add_and_lookup () =
  let s =
    match Span.make ~path:"a.md" ~start_byte:0 ~end_byte:10 with
    | Ok s -> s | Error _ -> failwith "span"
  in
  let r = Resolution.add_asset s ~routed_path:"pkg/x.png" Resolution.empty in
  Alcotest.(check (option string)) "resolution lookup"
    (Some "pkg/x.png") (Resolution.asset_route r s)

let test_resolution_different_span () =
  let s1 =
    match Span.make ~path:"a.md" ~start_byte:0 ~end_byte:10 with
    | Ok s -> s | Error _ -> failwith "span"
  in
  let s2 =
    match Span.make ~path:"a.md" ~start_byte:11 ~end_byte:20 with
    | Ok s -> s | Error _ -> failwith "span"
  in
  let r = Resolution.add_asset s1 ~routed_path:"pkg/x.png" Resolution.empty in
  Alcotest.(check (option string)) "other span not found"
    None (Resolution.asset_route r s2)

(* ── LF normalization ── *)

let test_lf_normalization () =
  let t = outline_blocks "test" [para [text_inline "hello"]] in
  let result = emit_str t in
  Alcotest.(check bool) "no CR"
    true (not (String.contains result '\r'))

(* ── No extra wrapper around transclusion ── *)

let test_transclusion_no_extra_wrapper () =
  let t = outline_blocks "test" [block_embed "other.tree"] in
  let result = emit_str t in
  Alcotest.(check bool) "direct transclude"
    true (string_contains result "\\transclude{other.tree}");
  Alcotest.(check bool) "no paragraph wrapper"
    true (not (string_contains result "\\p{\\transclude"))

(* ── Nesting: emphasis inside strong inside link ── *)

let test_deeply_nested_inlines () =
  let t = outline_blocks "test" [para [
    external_link [emph [strong [text_inline "deep"]]] "https://example.test" None
  ]] in
  Alcotest.(check string) "deeply nested inlines"
    "\\title{test}\n\\p{[\\em{\\strong{deep}}](https://example.test)}\n"
    (emit_str t)

(* ── Run ── *)

let () =
  let open Alcotest in
  run "Forester_6"
    [ "target", [
        test_case "target_string" `Quick test_target_string;
      ]
    ; "escaping", [
        test_case "escape_percent" `Quick test_escape_percent;
        test_case "escape_backslash" `Quick test_escape_backslash;
        test_case "escape_hash" `Quick test_escape_hash;
        test_case "escape_lbrace" `Quick test_escape_lbrace;
        test_case "escape_rbrace" `Quick test_escape_rbrace;
        test_case "escape_lbracket" `Quick test_escape_lbracket;
        test_case "escape_rbracket" `Quick test_escape_rbracket;
        test_case "escape_lparen" `Quick test_escape_lparen;
        test_case "escape_rparen" `Quick test_escape_rparen;
        test_case "escape_unchanged" `Quick test_escape_unchanged;
        test_case "escape_mixed" `Quick test_escape_mixed;
        test_case "escape_full_string" `Quick test_escape_full_string;
      ]
    ; "emission_basic", [
        test_case "simple_paragraph" `Quick test_simple_paragraph;
        test_case "empty_body" `Quick test_empty_body;
        test_case "emphasis_emission" `Quick test_emphasis_emission;
        test_case "strong_emission" `Quick test_strong_emission;
        test_case "inline_code_emission" `Quick test_inline_code_emission;
        test_case "hard_break_emission" `Quick test_hard_break_emission;
        test_case "soft_break_emission" `Quick test_soft_break_emission;
        test_case "mixed_inlines" `Quick test_mixed_inlines;
        test_case "deeply_nested_inlines" `Quick test_deeply_nested_inlines;
        test_case "hostile_inline_code" `Quick test_hostile_inline_code;
      ]
    ; "emission_math", [
        test_case "inline_math_emission" `Quick test_inline_math_emission;
        test_case "display_math_inline_emission" `Quick test_display_math_inline_emission;
        test_case "display_math_block_emission" `Quick test_display_math_block_emission;
        test_case "math_unbalanced_error" `Quick test_math_unbalanced_error;
        test_case "math_balanced_passes" `Quick test_math_balanced_passes;
      ]
    ; "emission_links", [
        test_case "external_link_emission" `Quick test_external_link_emission;
        test_case "http_link_emission" `Quick test_http_link_emission;
        test_case "external_link_with_title" `Quick test_external_link_with_title;
        test_case "wiki_link_emission" `Quick test_wiki_link_emission;
        test_case "wiki_link_alias_emission" `Quick test_wiki_link_alias_emission;
        test_case "wiki_embed_emission" `Quick test_wiki_embed_emission;
        test_case "resolved_reference_uses_identity" `Quick test_resolved_reference_uses_identity;
      ]
    ; "emission_images", [
        test_case "external_image_emission" `Quick test_external_image_emission;
        test_case "http_image_emission" `Quick test_http_image_emission;
        test_case "local_image_with_resolution" `Quick test_local_image_with_resolution;
        test_case "local_image_no_resolution_error" `Quick test_local_image_no_resolution_error;
        test_case "image_alt_flattening" `Quick test_image_alt_flattening;
      ]
    ; "emission_blocks", [
        test_case "blockquote_emission" `Quick test_blockquote_emission;
        test_case "thematic_break_emission" `Quick test_thematic_break_emission;
        test_case "code_block_no_lang" `Quick test_code_block_no_lang;
        test_case "code_block_with_lang" `Quick test_code_block_with_lang;
        test_case "block_embed_emission" `Quick test_block_embed_emission;
        test_case "code_block_multiline" `Quick test_code_block_multiline;
        test_case "multiple_blocks_separated" `Quick test_multiple_blocks_separated;
        test_case "xml_attr_escaping" `Quick test_xml_attr_escaping;
        test_case "hostile_code_block_content" `Quick test_hostile_code_block_content;
      ]
    ; "emission_lists", [
        test_case "tight_unordered_list" `Quick test_tight_unordered_list;
        test_case "loose_unordered_list" `Quick test_loose_unordered_list;
        test_case "tight_ordered_list_start_1" `Quick test_tight_ordered_list_start_1;
        test_case "ordered_list_start_7" `Quick test_ordered_list_start_7;
        test_case "loose_ordered_list_start_3" `Quick test_loose_ordered_list_start_3;
      ]
    ; "emission_metadata", [
        test_case "metadata_date" `Quick test_metadata_date;
        test_case "metadata_taxon" `Quick test_metadata_taxon;
        test_case "metadata_authors_literal" `Quick test_metadata_authors_literal;
        test_case "metadata_authors_tree" `Quick test_metadata_authors_tree;
        test_case "metadata_contributors" `Quick test_metadata_contributors;
        test_case "metadata_tags" `Quick test_metadata_tags;
        test_case "metadata_meta" `Quick test_metadata_meta;
        test_case "metadata_order" `Quick test_metadata_order;
      ]
    ; "emission_sections", [
        test_case "named_and_anon_sections" `Quick test_named_and_anon_sections;
      ]
    ; "emission_edge", [
        test_case "utf8_text" `Quick test_utf8_text;
        test_case "final_newline" `Quick test_final_newline;
        test_case "lf_normalization" `Quick test_lf_normalization;
        test_case "hostile_chars_in_paragraph" `Quick test_hostile_chars_in_paragraph;
        test_case "transclusion_no_extra_wrapper" `Quick test_transclusion_no_extra_wrapper;
      ]
    ; "untitled_subtrees", [
        test_case "untitled_subtree_omits_title" `Quick test_untitled_subtree_omits_title;
        test_case "untitled_subtree_keeps_id" `Quick test_untitled_subtree_keeps_id;
        test_case "block_after_subtree_keeps_order" `Quick test_block_after_subtree_keeps_order;
        test_case "nested_untitled_subtree" `Quick test_nested_untitled_subtree;
      ]
    ; "resolution", [
        test_case "resolution_empty" `Quick test_resolution_empty;
        test_case "resolution_add_and_lookup" `Quick test_resolution_add_and_lookup;
        test_case "resolution_different_span" `Quick test_resolution_different_span;
      ]
    ]
