open Tree_md

(* ── Test helpers ── *)

let zero_span =
  match Span.make ~path:"test.md" ~start_byte:0 ~end_byte:0 with
  | Ok s -> s | Error _ -> failwith "cannot create span"

let text_inline s = { Ir.node = Ir.Text s; Ir.span = zero_span }
let heading level title =
  { Ir.bnode = Ir.Heading { level; title = [text_inline title] }; Ir.bspan = zero_span }
let para text =
  { Ir.bnode = Ir.Paragraph [text_inline text]; Ir.bspan = zero_span }
let directive id =
  { Ir.bnode = Ir.Subtree_directive id; Ir.bspan = zero_span }
let embed id =
  { Ir.bnode = Ir.Block_embed id; Ir.bspan = zero_span }
let thematic () =
  { Ir.bnode = Ir.Thematic_break; Ir.bspan = zero_span }

let empty_meta : Ir.inline list Metadata.t =
  { Metadata.date = None; Metadata.taxon = None;
    Metadata.authors = []; Metadata.contributors = [];
    Metadata.tags = []; Metadata.meta = [] }

let doc blocks =
  { Ir.metadata = empty_meta; Ir.blocks = blocks; Ir.doc_span = zero_span }

let has_code diags code =
  List.exists (fun d -> Diagnostic.code_string d.Diagnostic.code = code) diags

let inline_text i = match i.Ir.node with Ir.Text s -> s | _ -> ""

let title_texts title = List.map inline_text title

let span_at start_byte end_byte =
  match Span.make ~path:"test.md" ~start_byte ~end_byte with
  | Ok s -> s | Error _ -> failwith "cannot create span"

let custom_directive id sp = { Ir.bnode = Ir.Subtree_directive id; Ir.bspan = sp }
let custom_heading level title sp =
  { Ir.bnode = Ir.Heading { level; title = [text_inline title] }; Ir.bspan = sp }
let custom_para text sp = { Ir.bnode = Ir.Paragraph [text_inline text]; Ir.bspan = sp }

(* ── H1 first: becomes root title, no sections ── *)

let test_h1_root_title () =
  match Outline.build ~root_id:"test" (doc [heading 1 "My Title"]) with
  | Ok tree ->
    Alcotest.(check string) "root_id" "test" tree.root_id;
    Alcotest.(check (list string)) "title" ["My Title"] (title_texts tree.title);
    Alcotest.(check int) "empty body" 0 (List.length tree.body);
    Alcotest.(check int) "no sections" 0 (List.length tree.sections);
    Alcotest.(check int) "no definitions" 0 (List.length (Outline.definitions tree))
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── No H1: root_id becomes Text node root title ── *)

let test_no_h1_fallback () =
  match Outline.build ~root_id:"myfile" (doc [para "hello"]) with
  | Ok tree ->
    Alcotest.(check string) "root_id" "myfile" tree.root_id;
    (match tree.title with
     | [{ Ir.node = Ir.Text "myfile"; _ }] -> ()
     | _ -> Alcotest.fail "expected root title 'myfile'");
    Alcotest.(check int) "one body block" 1 (List.length tree.body);
    Alcotest.(check int) "no sections" 0 (List.length tree.sections)
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── H1 with body and H2 sections ── *)

let test_h1_with_body_and_sections () =
  match Outline.build ~root_id:"t" (doc [
    heading 1 "Root";
    para "intro";
    heading 2 "A";
    para "body A";
    heading 2 "B";
  ]) with
  | Ok tree ->
    Alcotest.(check (list string)) "root title" ["Root"] (title_texts tree.title);
    Alcotest.(check int) "one body block" 1 (List.length tree.body);
    Alcotest.(check int) "two root sections" 2 (List.length tree.sections)
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── H2 H3 H3 H2 hierarchy: two root sections, first has two children ── *)

let test_h2_h3_h3_h2 () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    heading 3 "B";
    heading 3 "C";
    heading 2 "D";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "two root sections" 2 (List.length tree.sections);
    (match tree.sections with
     | [s1; s2] ->
       Alcotest.(check (list string)) "s1 title" ["A"] (title_texts s1.title);
       Alcotest.(check int) "s1 has 2 children" 2 (List.length s1.children);
       (match s1.children with
        | [c1; c2] ->
          Alcotest.(check (list string)) "c1 title" ["B"] (title_texts c1.title);
          Alcotest.(check (list string)) "c2 title" ["C"] (title_texts c2.title)
        | _ -> Alcotest.fail "expected 2 children");
       Alcotest.(check (list string)) "s2 title" ["D"] (title_texts s2.title);
       Alcotest.(check int) "s2 has 0 children" 0 (List.length s2.children)
     | _ -> Alcotest.fail "expected 2 sections")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Body attachment: paragraphs stay in their section ── *)

let test_body_attachment () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    para "intro";
    heading 3 "B";
    para "details";
    para "more details";
    heading 2 "C";
    para "end";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "two root sections" 2 (List.length tree.sections);
    (match tree.sections with
     | [s1; s2] ->
       (* s1 body has "intro" before child section *)
       Alcotest.(check int) "s1 body 1 block" 1 (List.length s1.body);
       Alcotest.(check int) "s1 has 1 child" 1 (List.length s1.children);
       (match s1.children with
        | [c] ->
          Alcotest.(check (list string)) "child title" ["B"] (title_texts c.title);
          Alcotest.(check int) "child body 2 blocks" 2 (List.length c.body)
        | _ -> Alcotest.fail "expected 1 child");
       Alcotest.(check (list string)) "s2 title" ["C"] (title_texts s2.title);
       Alcotest.(check int) "s2 body 1 block" 1 (List.length s2.body)
     | _ -> Alcotest.fail "expected 2 sections")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Same level closes section ── *)

let test_same_level_closes () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    para "a1";
    heading 2 "B";
    para "b1";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "two sections" 2 (List.length tree.sections);
    (match tree.sections with
     | [s1; s2] ->
       Alcotest.(check int) "s1 body" 1 (List.length s1.body);
       Alcotest.(check int) "s2 body" 1 (List.length s2.body)
     | _ -> Alcotest.fail "expected 2 sections")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Shallower level closes higher level ── *)

let test_shallower_closes_deeper () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    heading 3 "B";
    para "b1";
    heading 2 "C";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "two root sections" 2 (List.length tree.sections);
    (match tree.sections with
     | [s1; s2] ->
       Alcotest.(check int) "s1 has 1 child" 1 (List.length s1.children);
       Alcotest.(check (list string)) "s2 title" ["C"] (title_texts s2.title)
     | _ -> Alcotest.fail "expected 2 sections")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Orphan directive inside section: TM104 ── *)

let test_orphan_directive_in_section () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    directive "orphan";
    para "body";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM104 for orphaned directive inside section"
  | Error diags ->
    Alcotest.(check bool) "TM104" true (has_code diags "TM104")

(* ── Paragraph then H1: TM103 (H1 not first block) ── *)

let test_para_then_h1 () =
  match Outline.build ~root_id:"t" (doc [
    para "text";
    heading 1 "Title";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM103 for H1 after non-heading block"
  | Error diags ->
    Alcotest.(check bool) "TM103" true (has_code diags "TM103")

(* ── Second H1: TM103 ── *)

let test_second_h1 () =
  match Outline.build ~root_id:"t" (doc [
    heading 1 "First";
    heading 1 "Second";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM103 for second H1"
  | Error diags ->
    Alcotest.(check bool) "TM103" true (has_code diags "TM103")

(* ── H1 after H2: TM103 ── *)

let test_h1_after_h2 () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    heading 1 "B";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM103 for H1 after sections"
  | Error diags ->
    Alcotest.(check bool) "TM103" true (has_code diags "TM103")

(* ── Directive then H2: named section ── *)

let test_directive_then_h2 () =
  match Outline.build ~root_id:"t" (doc [
    directive "my.tree";
    heading 2 "Section";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "one section" 1 (List.length tree.sections);
    (match tree.sections with
     | [s] ->
       Alcotest.(check (option string)) "named section" (Some "my.tree") s.id
     | _ -> Alcotest.fail "expected 1 section");
    let defs = Outline.definitions tree in
    Alcotest.(check int) "one definition" 1 (List.length defs);
    (match defs with
     | [d] -> Alcotest.(check string) "definition id" "my.tree" d.id
     | _ -> Alcotest.fail "expected 1 definition")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Directive, blank lines, H2: named section (blank lines don't exist in IR) ── *)

let test_directive_blank_h2 () =
  match Outline.build ~root_id:"t" (doc [
    directive "named";
    heading 2 "S";
  ]) with
  | Ok tree ->
    (match tree.sections with
     | [s] ->
       Alcotest.(check (option string)) "named section" (Some "named") s.id
     | _ -> Alcotest.fail "expected 1 section")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Directive then paragraph: TM104 ── *)

let test_directive_then_para () =
  match Outline.build ~root_id:"t" (doc [
    directive "orphan";
    para "text";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM104 for orphaned directive"
  | Error diags ->
    Alcotest.(check bool) "TM104" true (has_code diags "TM104")

(* ── Two directives before H2: TM104 (first directive lost, second applied) ── *)

let test_two_directives_before_h2 () =
  match Outline.build ~root_id:"t" (doc [
    directive "first";
    directive "second";
    heading 2 "S";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM104 for multiple directives without heading"
  | Error diags ->
    Alcotest.(check bool) "TM104" true (has_code diags "TM104")

(* ── Directive before H1: TM104 ── *)

let test_directive_before_h1 () =
  match Outline.build ~root_id:"t" (doc [
    directive "bad";
    heading 1 "Title";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM104 for directive before H1"
  | Error diags ->
    Alcotest.(check bool) "TM104" true (has_code diags "TM104")

(* ── Directive applied to H3 (sub-section) ── *)

let test_directive_on_h3 () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    directive "child.tree";
    heading 3 "Child";
  ]) with
  | Ok tree ->
    (match tree.sections with
     | [s] ->
       (match s.children with
        | [c] ->
          Alcotest.(check (option string)) "named child" (Some "child.tree") c.id
        | _ -> Alcotest.fail "expected 1 child")
     | _ -> Alcotest.fail "expected 1 section");
    let defs = Outline.definitions tree in
    Alcotest.(check int) "one definition" 1 (List.length defs)
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Definitions: multiple named sections ── *)

let test_multiple_definitions () =
  match Outline.build ~root_id:"t" (doc [
    directive "a";
    heading 2 "A";
    directive "b";
    heading 2 "B";
    directive "c";
    heading 2 "C";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "three sections" 3 (List.length tree.sections);
    let defs = Outline.definitions tree in
    Alcotest.(check int) "three definitions" 3 (List.length defs);
    let ids = List.map (fun (d : Outline.definition) -> d.id) defs in
    Alcotest.(check (list string)) "def ids" ["a"; "b"; "c"] ids
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Definition span points at directive source span, not heading span ── *)

let test_definition_span_points_to_directive () =
  let dir_sp = span_at 10 25 in
  let h2_sp = span_at 30 40 in
  match Outline.build ~root_id:"t" (doc [
    custom_directive "named" dir_sp;
    custom_heading 2 "S" h2_sp;
  ]) with
  | Ok tree ->
    (match tree.sections with
     | [s] ->
       Alcotest.(check (option string)) "id matches" (Some "named") s.id;
       (match s.definition_span with
        | Some ds ->
          Alcotest.(check int) "def_span start matches directive" dir_sp.Span.start_byte ds.Span.start_byte;
          Alcotest.(check int) "def_span end matches directive" dir_sp.Span.end_byte ds.Span.end_byte
        | None -> Alcotest.fail "expected definition_span");
       let defs = Outline.definitions tree in
       (match defs with
        | [d] ->
          Alcotest.(check int) "def start matches directive" dir_sp.Span.start_byte d.span.Span.start_byte;
          Alcotest.(check int) "def end matches directive" dir_sp.Span.end_byte d.span.Span.end_byte
        | _ -> Alcotest.fail "expected 1 definition")
     | _ -> Alcotest.fail "expected 1 section")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Section span covers heading through body and children end ── *)

let test_section_span_covers_range () =
  let h2_sp = span_at 10 20 in
  let p1_sp = span_at 30 40 in
  let p2_sp = span_at 50 60 in
  let h3_sp = span_at 70 80 in
  let p3_sp = span_at 90 100 in
  match Outline.build ~root_id:"t" (doc [
    custom_heading 2 "A" h2_sp;
    custom_para "a1" p1_sp;
    custom_para "a2" p2_sp;
    custom_heading 3 "B" h3_sp;
    custom_para "b1" p3_sp;
  ]) with
  | Ok tree ->
    (match tree.sections with
     | [s1] ->
       Alcotest.(check int) "s1 span start" h2_sp.Span.start_byte s1.span.Span.start_byte;
       Alcotest.(check int) "s1 span end covers children" p3_sp.Span.end_byte s1.span.Span.end_byte;
       (match s1.children with
        | [c1] ->
          Alcotest.(check int) "c1 span start" h3_sp.Span.start_byte c1.span.Span.start_byte;
          Alcotest.(check int) "c1 span end" p3_sp.Span.end_byte c1.span.Span.end_byte
        | _ -> Alcotest.fail "expected 1 child")
     | _ -> Alcotest.fail "expected 1 section")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Root title fallback span is valid ── *)

let test_fallback_span () =
  match Outline.build ~root_id:"myfile" (doc [para "x"]) with
  | Ok tree ->
    (match tree.title with
     | [{ Ir.span; _ }] ->
       Alcotest.(check int) "fallback start_byte 0" 0 span.Span.start_byte;
       Alcotest.(check int) "fallback end_byte 0" 0 span.Span.end_byte
     | _ -> Alcotest.fail "expected single Text inline")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Empty document: root_id fallback, no errors ── *)

let test_empty_document () =
  match Outline.build ~root_id:"empty" (doc []) with
  | Ok tree ->
    Alcotest.(check (list string)) "fallback title" ["empty"] (title_texts tree.title);
    Alcotest.(check int) "no body" 0 (List.length tree.body);
    Alcotest.(check int) "no sections" 0 (List.length tree.sections)
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── H1 plus body then H2: body goes to root ── *)

let test_h1_body_then_h2 () =
  match Outline.build ~root_id:"t" (doc [
    heading 1 "Root";
    para "intro";
    para "more";
    heading 2 "A";
    para "section body";
  ]) with
  | Ok tree ->
    Alcotest.(check int) "root body 2 blocks" 2 (List.length tree.body);
    Alcotest.(check int) "one section" 1 (List.length tree.sections);
    (match tree.sections with
     | [s] ->
       Alcotest.(check int) "section body 1 block" 1 (List.length s.body)
     | _ -> Alcotest.fail "expected 1 section")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Non-heading blocks between headings go to correct section ── *)

let test_non_heading_between_headings () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    para "a_body";
    embed "note";
    thematic ();
    heading 3 "B";
    para "b_body";
    heading 3 "C";
    heading 2 "D";
    para "d_body";
  ]) with
  | Ok tree ->
    (match tree.sections with
     | [s1; s2] ->
       Alcotest.(check int) "s1 body 3 blocks" 3 (List.length s1.body);
       Alcotest.(check int) "s1 2 children" 2 (List.length s1.children);
       (match s1.children with
        | [c1; c2] ->
          Alcotest.(check int) "c1 body 1 block" 1 (List.length c1.body);
          Alcotest.(check int) "c2 body 0 blocks" 0 (List.length c2.body)
        | _ -> Alcotest.fail "expected 2 children");
       Alcotest.(check int) "s2 body 1 block" 1 (List.length s2.body)
     | _ -> Alcotest.fail "expected 2 sections")
  | Error diags ->
    let msgs = List.map (fun d -> d.Diagnostic.message) diags |> String.concat "; " in
    Alcotest.fail ("expected Ok, got: " ^ msgs)

(* ── Directive at end (no heading): TM104 ── *)

let test_directive_at_end () =
  match Outline.build ~root_id:"t" (doc [
    para "start";
    directive "unused";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM104 for directive at end of document"
  | Error diags ->
    Alcotest.(check bool) "TM104" true (has_code diags "TM104")

(* ── TM103 when only H2, H4: level skipped at H4 ── *)

let test_level_skip_h2_to_h4 () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    heading 4 "D";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM103"
  | Error diags ->
    Alcotest.(check bool) "TM103" true (has_code diags "TM103")

(* ── TM103 when H3 appears without H2 ── *)

let test_h3_without_h2 () =
  match Outline.build ~root_id:"t" (doc [
    heading 3 "No H2";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM103 for H3 without H2"
  | Error diags ->
    Alcotest.(check bool) "TM103" true (has_code diags "TM103")

(* ── TM103 when H5 appears after H3 ── *)

let test_level_skip_h3_to_h5 () =
  match Outline.build ~root_id:"t" (doc [
    heading 2 "A";
    heading 3 "B";
    heading 5 "E";
  ]) with
  | Ok _ -> Alcotest.fail "expected TM103"
  | Error diags ->
    Alcotest.(check bool) "TM103" true (has_code diags "TM103")

(* ── Run ── *)

let () =
  let open Alcotest in
  run "Outline"
    [ "root_title", [
        test_case "h1_root_title" `Quick test_h1_root_title;
        test_case "no_h1_fallback" `Quick test_no_h1_fallback;
        test_case "h1_with_body_and_sections" `Quick test_h1_with_body_and_sections;
        test_case "fallback_span" `Quick test_fallback_span;
        test_case "empty_document" `Quick test_empty_document;
      ]
    ; "hierarchy", [
        test_case "h2_h3_h3_h2" `Quick test_h2_h3_h3_h2;
        test_case "body_attachment" `Quick test_body_attachment;
        test_case "same_level_closes" `Quick test_same_level_closes;
        test_case "shallower_closes_deeper" `Quick test_shallower_closes_deeper;
        test_case "non_heading_between_headings" `Quick test_non_heading_between_headings;
        test_case "h1_body_then_h2" `Quick test_h1_body_then_h2;
        test_case "section_span_covers_range" `Quick test_section_span_covers_range;
      ]
    ; "directives", [
        test_case "directive_then_h2" `Quick test_directive_then_h2;
        test_case "directive_blank_h2" `Quick test_directive_blank_h2;
        test_case "directive_on_h3" `Quick test_directive_on_h3;
        test_case "multiple_definitions" `Quick test_multiple_definitions;
        test_case "definition_span_points_to_directive" `Quick test_definition_span_points_to_directive;
      ]
    ; "errors", [
        test_case "orphan_directive_in_section" `Quick test_orphan_directive_in_section;
        test_case "para_then_h1" `Quick test_para_then_h1;
        test_case "second_h1" `Quick test_second_h1;
        test_case "h1_after_h2" `Quick test_h1_after_h2;
        test_case "directive_then_para" `Quick test_directive_then_para;
        test_case "two_directives_before_h2" `Quick test_two_directives_before_h2;
        test_case "directive_before_h1" `Quick test_directive_before_h1;
        test_case "directive_at_end" `Quick test_directive_at_end;
        test_case "level_skip_h2_to_h4" `Quick test_level_skip_h2_to_h4;
        test_case "h3_without_h2" `Quick test_h3_without_h2;
        test_case "level_skip_h3_to_h5" `Quick test_level_skip_h3_to_h5;
      ]
    ]
