(* Each compile stage now returns its warnings alongside the value it
   produced. These suites assert on the value, so they drop the warnings. *)
(* Front matter is read in two steps now: the parser builds the mapping, and
   Metadata.of_yaml reads the keys tree-md emits out of it. These suites are
   about the pair, so the helper runs both and gates their diagnostics
   together, which is what the compiler does. *)
module Frontmatter = struct
  type t = {
    frontmatter : Tree_md.Yaml_json.t option;
    metadata : Tree_md.Metadata.raw;
    masked_markdown : string;
  }
end

let parse_both source =
  match Tree_md.Frontmatter.parse source with
  | Error diags -> Error diags
  | Ok (parsed, warnings) ->
    let metadata, lowering =
      Tree_md.Metadata.of_yaml parsed.Tree_md.Frontmatter.frontmatter
    in
    Tree_md.Diagnostic.gate
      { Frontmatter.frontmatter = parsed.Tree_md.Frontmatter.frontmatter;
        metadata;
        masked_markdown = parsed.Tree_md.Frontmatter.masked_markdown }
      (warnings @ lowering)

let parse_frontmatter source = Result.map fst (parse_both source)

let contains haystack needle =
  let n = String.length needle in
  let rec loop i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  loop 0

(* Some suites are about the warnings themselves, so they keep both. *)
let parse_with_diagnostics source = parse_both source

let diagnostic_summary diags =
  List.map
    (fun d ->
      Printf.sprintf "%s %s: %s"
        (Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code)
        (Tree_md.Diagnostic.severity_string d.Tree_md.Diagnostic.severity)
        d.Tree_md.Diagnostic.message)
    diags
  |> String.concat "; "

let valid_source =
  "---\r\n" ^
  "date: \"2026-08-02T09:30:00+09:00\"\r\n" ^
  "taxon: Note\r\n" ^
  "authors: [\"[[miya]]\", \"Ada Lovelace\"]\r\n" ^
  "tags: [\"**compiler**\"]\r\n" ^
  "meta: { institution: \"[Tsukuba](https://example.test/)\" }\r\n" ^
  "---\r\n# Title\r\n"

let valid_source_path = "note.tree.md"

let validate_result result =
  match result with
  | Ok t -> t
  | Error diags ->
    let msgs =
      List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; "
    in
    Alcotest.fail ("expected Ok, got errors: " ^ msgs)

let test_valid_frontmatter () =
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:valid_source_path valid_source)
  in
  let result = parse_frontmatter source in
  let t = validate_result result in
  (* Masked markdown has same byte length as original *)
  Alcotest.(check int) "masked byte length equals original"
    (String.length valid_source) (String.length t.masked_markdown);
  (* CR and LF bytes preserved in masked markdown *)
  let original_length = String.length valid_source in
  let has_cr i = i > 0 && i < original_length
    && valid_source.[i] = '\r'
  in
  let has_lf i = valid_source.[i] = '\n' in
  let check_newline_bytes () =
    for i = 0 to original_length - 1 do
      if has_cr i then
        Alcotest.(check char) (Printf.sprintf "byte %d is CR" i)
          '\r' t.masked_markdown.[i];
      if has_lf i then
        Alcotest.(check char) (Printf.sprintf "byte %d is LF" i)
          '\n' t.masked_markdown.[i]
    done
  in
  check_newline_bytes ();
  (* Non-newline bytes in frontmatter are spaces *)
  let closing_delim_start =
    let idx = ref 0 in
    while !idx < original_length
      && not (valid_source.[!idx] = '-' && valid_source.[!idx+1] = '-'
              && valid_source.[!idx+2] = '-'
              && (!idx = 0 || valid_source.[!idx-1] = '\n'))
    do
      incr idx
    done;
    if !idx = 0 then begin
      (* opening --- at 0; find closing --- *)
      idx := 4;
      while !idx < original_length
        && not (valid_source.[!idx] = '-' && valid_source.[!idx+1] = '-'
                && valid_source.[!idx+2] = '-'
                && (!idx = 0 || valid_source.[!idx-1] = '\n'))
      do
        incr idx
      done;
    end;
    !idx
  in
  let closing_end = closing_delim_start + 3 in
  for i = 0 to closing_end do
    if not (has_cr i) && not (has_lf i) then
      Alcotest.(check char) (Printf.sprintf "fm byte %d masked to space" i)
        ' ' t.masked_markdown.[i]
  done;
  (* Title text preserved after frontmatter *)
  let body_start = closing_end in
  let body_end = String.length t.masked_markdown in
  let body = String.sub t.masked_markdown body_start (body_end - body_start) in
  Alcotest.(check bool) "masked content has # Title"
    true (String.contains_from body 0 '#');
  (* Metadata assertions *)
  let meta = t.metadata in
  (* date *)
  (match meta.date with
   | Some d ->
     Alcotest.(check string) "date value"
       "2026-08-02T09:30:00+09:00" d.value;
     Alcotest.(check bool) "date span valid"
       true (d.span.Tree_md.Span.start_byte > 0
             && d.span.Tree_md.Span.end_byte > d.span.Tree_md.Span.start_byte);
   | None -> Alcotest.fail "expected date");
  (* taxon *)
  (match meta.taxon with
   | Some tx ->
     Alcotest.(check string) "taxon value" "Note" tx.value;
   | None -> Alcotest.fail "expected taxon");
  (* authors: tree and literal *)
  (match meta.authors with
   | [Tree t; Literal l] ->
     Alcotest.(check string) "tree author" "miya" t.value;
     Alcotest.(check string) "literal author" "Ada Lovelace" l.value;
   | _ -> Alcotest.fail "expected two authors: Tree miya, Literal Ada Lovelace");
  (* tags *)
  (match meta.tags with
   | [tag] ->
     Alcotest.(check string) "tag value" "**compiler**" tag.value;
   | _ -> Alcotest.fail "expected one tag");
  (* meta *)
  (match meta.meta with
   | [(key, value)] ->
     Alcotest.(check string) "meta key" "institution" key.value;
     Alcotest.(check string) "meta value"
       "[Tsukuba](https://example.test/)" value.value;
   | _ -> Alcotest.fail "expected one meta pair")

let test_valid_id () =
  Alcotest.(check bool) "valid_id miya" true (Tree_md.Metadata.valid_id "miya");
  Alcotest.(check bool) "valid_id Miya" true (Tree_md.Metadata.valid_id "Miya");
  Alcotest.(check bool) "valid_id my.id" true (Tree_md.Metadata.valid_id "my.id");
  Alcotest.(check bool) "valid_id my_id" true (Tree_md.Metadata.valid_id "my_id");
  Alcotest.(check bool) "valid_id my-id" true (Tree_md.Metadata.valid_id "my-id");
  Alcotest.(check bool) "valid_id empty" false (Tree_md.Metadata.valid_id "");
  Alcotest.(check bool) "valid_id space" false (Tree_md.Metadata.valid_id "bad id");
  Alcotest.(check bool) "valid_id starts with dot" false (Tree_md.Metadata.valid_id ".bad");
  Alcotest.(check bool) "valid_id starts with underscore" false (Tree_md.Metadata.valid_id "_bad")

let test_parse_attribution_tree () =
  let sp = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:8) in
  let located = { Tree_md.Metadata.value = "[[miya]]"; span = sp } in
  match Tree_md.Metadata.parse_attribution located with
  | Ok (Tree t) ->
    Alcotest.(check string) "tree inner value" "miya" t.value
  | Ok (Literal _) -> Alcotest.fail "expected Tree"
  | Error d -> Alcotest.fail ("expected Ok, got: " ^ d.Tree_md.Diagnostic.message)

let test_parse_attribution_literal () =
  let sp = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:13) in
  let located = { Tree_md.Metadata.value = "Ada Lovelace"; span = sp } in
  match Tree_md.Metadata.parse_attribution located with
  | Ok (Literal l) ->
    Alcotest.(check string) "literal value" "Ada Lovelace" l.value
  | Ok (Tree _) -> Alcotest.fail "expected Literal"
  | Error d -> Alcotest.fail ("expected Ok, got: " ^ d.Tree_md.Diagnostic.message)

let test_parse_attribution_bad_id () =
  let sp = Result.get_ok (Tree_md.Span.make ~path:"test.md" ~start_byte:0 ~end_byte:11) in
  let located = { Tree_md.Metadata.value = "[[bad id]]"; span = sp } in
  match Tree_md.Metadata.parse_attribution located with
  | Ok _ -> Alcotest.fail "expected Error for bad id"
  | Error d ->
    Alcotest.(check string) "bad id diagnostic code"
      "TM101" (Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code)

let test_valid_date_format () =
  Alcotest.(check bool) "YYYY-MM-DD"
    true (Tree_md.Metadata.valid_date "2026-08-02");
  Alcotest.(check bool) "YYYY-MM-DDTHH:MM:SSZ"
    true (Tree_md.Metadata.valid_date "2026-08-02T09:30:00Z");
  Alcotest.(check bool) "YYYY-MM-DDTHH:MM:SS+HH:MM"
    true (Tree_md.Metadata.valid_date "2026-08-02T09:30:00+09:00");
  Alcotest.(check bool) "YYYY-MM-DDTHH:MM:SS-HH:MM"
    true (Tree_md.Metadata.valid_date "2026-08-02T09:30:00-05:00")

let test_valid_date_invalid () =
  Alcotest.(check bool) "lowercase t"
    false (Tree_md.Metadata.valid_date "2026-08-02t09:30:00Z");
  Alcotest.(check bool) "lowercase z"
    false (Tree_md.Metadata.valid_date "2026-08-02T09:30:00z");
  Alcotest.(check bool) "fractional seconds"
    false (Tree_md.Metadata.valid_date "2026-08-02T09:30:00.5Z");
  Alcotest.(check bool) "invalid month"
    false (Tree_md.Metadata.valid_date "2026-13-01");
  Alcotest.(check bool) "invalid day"
    false (Tree_md.Metadata.valid_date "2026-02-30");
  Alcotest.(check bool) "feb 29 non-leap"
    false (Tree_md.Metadata.valid_date "2025-02-29");
  Alcotest.(check bool) "feb 29 leap"
    true (Tree_md.Metadata.valid_date "2024-02-29");
  Alcotest.(check bool) "hour 24"
    false (Tree_md.Metadata.valid_date "2026-08-02T24:00:00Z");
  Alcotest.(check bool) "minute 60"
    false (Tree_md.Metadata.valid_date "2026-08-02T09:60:00Z");
  Alcotest.(check bool) "second 60"
    false (Tree_md.Metadata.valid_date "2026-08-02T09:30:60Z");
  Alcotest.(check bool) "offset hour 24"
    false (Tree_md.Metadata.valid_date "2026-08-02T09:30:00+24:00");
  Alcotest.(check bool) "offset minute 60"
    false (Tree_md.Metadata.valid_date "2026-08-02T09:30:00+09:60")

let expect_error diags expected_code =
  if List.length diags = 0 then
    Alcotest.fail ("expected diagnostics with " ^ expected_code)
  else
    let codes = List.map
      (fun d -> Tree_md.Diagnostic.code_string d.Tree_md.Diagnostic.code) diags
    in
    Alcotest.(check bool) ("has " ^ expected_code)
      true (List.mem expected_code codes)

let test_duplicate_keys () =
  let src_text =
    "---\n" ^
    "date: \"2026-08-02\"\n" ^
    "date: \"2026-08-03\"\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"dup.md" src_text)
  in
  match parse_frontmatter source with
  | Ok _ -> Alcotest.fail "expected error for duplicate keys"
  | Error diags -> expect_error diags "TM101"

(* Front matter is an arbitrary mapping (mdbase v0.3 §03). A key tree-md has
   no use for is carried, not rejected — an Obsidian vault is full of them. *)
let test_unknown_keys () =
  let src_text =
    "---\n" ^
    "aliases:\n" ^
    "  - 別名\n" ^
    "cssclasses: [wide]\n" ^
    "created: 2026-08-19\n" ^
    "publish: true\n" ^
    "unknown_key: value\n" ^
    "taxon: Note\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"unknown.md" src_text)
  in
  match parse_with_diagnostics source with
  | Error diags ->
    Alcotest.fail ("Obsidian front matter rejected: " ^ diagnostic_summary diags)
  | Ok (t, diags) ->
    Alcotest.(check string) "no diagnostics at all" "" (diagnostic_summary diags);
    (* Interpreted keys still land where they always did. *)
    Alcotest.(check (option string)) "taxon still read" (Some "Note")
      (Option.map (fun (v : _ Tree_md.Metadata.located) -> v.Tree_md.Metadata.value)
         t.Frontmatter.metadata.Tree_md.Metadata.taxon);
    Alcotest.(check (list string)) "nothing leaked into meta" []
      (List.map
         (fun ((k : string Tree_md.Metadata.located), _) -> k.Tree_md.Metadata.value)
         t.Frontmatter.metadata.Tree_md.Metadata.meta);
    (* And the mapping as written is carried whole. *)
    (match t.Frontmatter.frontmatter with
     | None -> Alcotest.fail "persisted front matter was dropped"
     | Some node ->
       Alcotest.(check (list string)) "every key kept, in source order"
         [ "aliases"; "cssclasses"; "created"; "publish"; "unknown_key"; "taxon" ]
         (List.map fst (Tree_md.Yaml_json.keys node)))

let test_yaml_alias () =
  let src_text =
    "---\n" ^
    "date: &anchor \"2026-08-02\"\n" ^
    "taxon: *anchor\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"alias.md" src_text)
  in
  match parse_frontmatter source with
  | Ok _ -> Alcotest.fail "expected error for YAML alias"
  | Error diags -> expect_error diags "TM101"

(* Front matter ends at the FIRST closing fence, as it does in Obsidian,
   Jekyll, Hugo and pandoc. A later `---` is body — a thematic break, or a
   setext underline — and is left in the body untouched rather than swallowed
   into the YAML. *)
let test_first_fence_closes_frontmatter () =
  let src_text =
    "---\n" ^
    "taxon: Note\n" ^
    "---\n" ^
    "\n" ^
    "Intro.\n" ^
    "\n" ^
    "---\n" ^
    "\n" ^
    "After the break.\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"break.md" src_text)
  in
  match parse_frontmatter source with
  | Error diags ->
    let messages =
      List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; "
    in
    Alcotest.fail ("a thematic break in the body was read as YAML: " ^ messages)
  | Ok t ->
    Alcotest.(check (option string)) "front matter stops at the first fence"
      (Some "Note")
      (Option.map (fun (v : _ Tree_md.Metadata.located) -> v.Tree_md.Metadata.value)
         t.Frontmatter.metadata.Tree_md.Metadata.taxon);
    (* Masking replaces only the front matter, so the body's own `---`
       survives into the Markdown the compiler sees. *)
    let body = t.Frontmatter.masked_markdown in
    Alcotest.(check int) "masking preserves length"
      (String.length src_text) (String.length body);
    Alcotest.(check bool) "the body keeps its thematic break" true
      (String.length body > 0
       && (let rec find i =
             i + 3 <= String.length body
             && ((String.sub body i 3 = "---" && i > 20) || find (i + 1))
           in
           find 0))

let test_missing_closing_delim () =
  let src_text =
    "---\n" ^
    "date: \"2026-08-02\"\n" ^
    "# Title without closing ---\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"no_close.md" src_text)
  in
  match parse_frontmatter source with
  | Ok _ -> Alcotest.fail "expected error for missing closing ---"
  | Error diags -> expect_error diags "TM002"

let test_no_frontmatter () =
  let src_text = "# Just a title\n" in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"no_fm.md" src_text)
  in
  match parse_frontmatter source with
  | Ok t ->
    Alcotest.(check string) "masked is original when no fm"
      src_text t.masked_markdown;
    Alcotest.(check bool) "no date when no fm"
      true (Option.is_none t.metadata.Tree_md.Metadata.date)
  | Error _ -> Alcotest.fail "expected Ok for no frontmatter"

let test_utf8_scalar_byte_mapping () =
  (* YAML scalar with Japanese: byte position of 日 is at offset 3 *)
  let src_text =
    "---\n" ^
    "taxon: 日Note\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"utf8.md" src_text)
  in
  match parse_frontmatter source with
  | Ok t ->
    (match t.metadata.Tree_md.Metadata.taxon with
     | Some tx ->
       Alcotest.(check string) "utf8 taxon value" "日Note" tx.value;
       (* 日 is 3 UTF-8 bytes, so the span should reflect the correct byte span *)
       Alcotest.(check bool) "taxon span covers utf8 bytes"
         true (tx.span.Tree_md.Span.end_byte - tx.span.Tree_md.Span.start_byte
               >= String.length "日Note")
     | None -> Alcotest.fail "expected taxon")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; "
    in
    Alcotest.fail ("expected Ok, got errors: " ^ msgs)

let test_multi_key_meta_then_taxon () =
  let src_text =
    "---\n" ^
    "meta: { a: \"1\", b: \"2\" }\n" ^
    "taxon: Note\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"multimeta.md" src_text)
  in
  match parse_frontmatter source with
  | Ok t ->
    (match t.Frontmatter.metadata.Tree_md.Metadata.meta with
     | [(k1, v1); (k2, v2)] ->
       Alcotest.(check string) "first meta key" "a" k1.Tree_md.Metadata.value;
       Alcotest.(check string) "first meta value" "1" v1.Tree_md.Metadata.value;
       Alcotest.(check string) "second meta key" "b" k2.Tree_md.Metadata.value;
       Alcotest.(check string) "second meta value" "2" v2.Tree_md.Metadata.value;
     | _ -> Alcotest.fail "expected two meta pairs in source order");
    (match t.Frontmatter.metadata.Tree_md.Metadata.taxon with
     | Some tx ->
       Alcotest.(check string) "taxon after meta" "Note" tx.Tree_md.Metadata.value;
     | None -> Alcotest.fail "expected taxon after meta")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; "
    in
    Alcotest.fail ("expected Ok, got errors: " ^ msgs)

let test_tag_real_spans () =
  let src_text =
    "---\n" ^
    "tags: [\"alpha\", \"beta\"]\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"tagspan.md" src_text)
  in
  match parse_frontmatter source with
  | Ok t ->
    (match t.Frontmatter.metadata.Tree_md.Metadata.tags with
     | [tag1; tag2] ->
       Alcotest.(check string) "tag1 value" "alpha" tag1.Tree_md.Metadata.value;
       Alcotest.(check string) "tag2 value" "beta" tag2.Tree_md.Metadata.value;
       (* Real spans: start_byte > 0 and end_byte > start_byte *)
       let sp1 = tag1.Tree_md.Metadata.span in
       let sp2 = tag2.Tree_md.Metadata.span in
       Alcotest.(check bool) "tag1 span valid"
         true (sp1.Tree_md.Span.start_byte > 0
               && sp1.Tree_md.Span.end_byte > sp1.Tree_md.Span.start_byte);
       Alcotest.(check bool) "tag2 span valid"
         true (sp2.Tree_md.Span.start_byte > 0
               && sp2.Tree_md.Span.end_byte > sp2.Tree_md.Span.start_byte)
     | _ -> Alcotest.fail "expected two tags")
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; "
    in
    Alcotest.fail ("expected Ok, got errors: " ^ msgs)

let test_non_scalar_key_rejected () =
  let src_text =
    "---\n" ^
    "{key}: value\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"nonscalar.md" src_text)
  in
  match parse_frontmatter source with
  | Ok _ -> Alcotest.fail "expected error for non-scalar key"
  | Error diags -> expect_error diags "TM101"

let meta_pairs t =
  List.map
    (fun ((k : string Tree_md.Metadata.located), (v : string Tree_md.Metadata.located)) ->
       (k.Tree_md.Metadata.value, v.Tree_md.Metadata.value))
    t.Frontmatter.metadata.Tree_md.Metadata.meta

let parse_ok path text =
  let source = Result.get_ok (Tree_md.Source.of_string ~path text) in
  match parse_frontmatter source with
  | Ok t -> t
  | Error diags ->
    let msgs = List.map (fun d -> d.Tree_md.Diagnostic.message) diags
      |> String.concat "; "
    in
    Alcotest.fail ("expected Ok, got errors: " ^ msgs)

(* A meta name written as a top-level key reaches the same place as one written
   under `meta:`, so it emits the same `\meta{}`. *)
let test_promoted_meta_keys () =
  let t =
    parse_ok "promoted.md"
      ("---\n" ^
       "taxon: Person\n" ^
       "institution: \"[Tsukuba](https://example.test/)\"\n" ^
       "orcid: \"0009-0000-4771-5212\"\n" ^
       "external: \"https://example.test/\"\n" ^
       "---\n# Title\n")
  in
  Alcotest.(check (list (pair string string))) "promoted keys in source order"
    [ ("institution", "[Tsukuba](https://example.test/)")
    ; ("orcid", "0009-0000-4771-5212")
    ; ("external", "https://example.test/")
    ]
    (meta_pairs t);
  match t.Frontmatter.metadata.Tree_md.Metadata.taxon with
  | Some tx -> Alcotest.(check string) "taxon still parsed" "Person" tx.Tree_md.Metadata.value
  | None -> Alcotest.fail "expected taxon"

(* Both spellings may be mixed; the combined list stays in source order. *)
let test_promoted_meta_mixed () =
  let t =
    parse_ok "mixed.md"
      ("---\n" ^
       "institution: \"Tsukuba\"\n" ^
       "meta: { custom-thing: \"kept\" }\n" ^
       "doi: \"10.0000/x\"\n" ^
       "---\n# Title\n")
  in
  Alcotest.(check (list (pair string string))) "top-level and nested interleave"
    [ ("institution", "Tsukuba")
    ; ("custom-thing", "kept")
    ; ("doi", "10.0000/x")
    ]
    (meta_pairs t)

let test_duplicate_meta_key () =
  let src_text =
    "---\n" ^
    "institution: \"Tsukuba\"\n" ^
    "meta: { institution: \"Elsewhere\" }\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"dupmeta.md" src_text)
  in
  match parse_frontmatter source with
  | Ok _ -> Alcotest.fail "expected error for a meta name set twice"
  | Error diags -> expect_error diags "TM101"

(* A key within an edit or two of one tree-md knows is far more likely a typo
   than a property. Dropping it in silence would lose a `\meta{}` with nothing
   to show for it, so it is said out loud — as a warning, which does not fail
   the build. *)
let test_misspelled_meta_key () =
  let src_text =
    "---\n" ^
    "instutition: \"Tsukuba\"\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"typo.md" src_text)
  in
  match parse_with_diagnostics source with
  | Error diags ->
    Alcotest.fail ("a misspelling failed the parse: " ^ diagnostic_summary diags)
  | Ok (_, diags) ->
    Alcotest.(check int) "exactly one diagnostic" 1 (List.length diags);
    let diag = List.hd diags in
    Alcotest.(check bool) "it is a warning" false
      (Tree_md.Diagnostic.is_error diag);
    Alcotest.(check string) "carries the mdbase code"
      "schema_additional_properties"
      (Option.value ~default:"" diag.Tree_md.Diagnostic.mdbase_code);
    Alcotest.(check bool) "names the key it meant" true
      (contains diag.Tree_md.Diagnostic.message "institution")

(* An `x-` key is the extension namespace mdbase v0.3 §05 reserves, so it is
   never a misspelling of anything. *)
let test_extension_key_never_warns () =
  let src_text =
    "---\n" ^
    "x-taxo: something\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"ext.md" src_text)
  in
  match parse_with_diagnostics source with
  | Error diags ->
    Alcotest.fail ("extension key rejected: " ^ diagnostic_summary diags)
  | Ok (_, diags) ->
    Alcotest.(check string) "silent" "" (diagnostic_summary diags)

(* A promoted key given a list used to confuse the reader's state machine into
   reading the second element as a top-level key. The reader now builds a tree
   and interprets nothing, so the shape cannot mislead it. *)
let test_promoted_key_with_list_value () =
  let src_text =
    "---\n" ^
    "toc: [a, b]\n" ^
    "---\n# Title\n"
  in
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"seq.md" src_text)
  in
  match parse_with_diagnostics source with
  | Error diags ->
    (* A list is not a string, so this is a type error naming `toc` — never a
       phantom unknown key called "b". *)
    Alcotest.(check bool) "names the key that is wrong" true
      (contains (diagnostic_summary diags) "toc");
    Alcotest.(check bool) "no phantom key" false
      (contains (diagnostic_summary diags) "\"b\"")
  | Ok (_, diags) ->
    Alcotest.(check bool) "no phantom key" false
      (contains (diagnostic_summary diags) "\"b\"")

(* Obsidian writes a single tag as a bare scalar as often as a list. *)
let test_scalar_tags_accepted () =
  let t = parse_ok "tag.md" "---\ntags: compiler\n---\n# Title\n" in
  Alcotest.(check (list string)) "one tag" [ "compiler" ]
    (List.map
       (fun (v : string Tree_md.Metadata.located) -> v.Tree_md.Metadata.value)
       t.Frontmatter.metadata.Tree_md.Metadata.tags)

(* A field read as text keeps the bytes it was written as, so a value YAML
   would resolve to a float is not rendered back with different digits. *)
let test_scalar_text_is_preserved () =
  let t = parse_ok "num.md" "---\ntaxon: 1.50\n---\n# Title\n" in
  Alcotest.(check (option string)) "written form kept" (Some "1.50")
    (Option.map (fun (v : _ Tree_md.Metadata.located) -> v.Tree_md.Metadata.value)
       t.Frontmatter.metadata.Tree_md.Metadata.taxon)

(* The identity may be stated rather than taken from the file name. *)
let test_id_key () =
  let t = parse_ok "id.md" ("---\nid: mlnet-7\ntaxon: Note\n---\n# Title\n") in
  match t.Frontmatter.metadata.Tree_md.Metadata.id with
  | Some located -> Alcotest.(check string) "id" "mlnet-7" located.Tree_md.Metadata.value
  | None -> Alcotest.fail "expected an id"

(* It still has to be a legal identity: it becomes a file name and a URL. *)
let test_invalid_id_rejected () =
  let source =
    Result.get_ok (Tree_md.Source.of_string ~path:"badid.md"
      "---\nid: \"not an id\"\n---\n# Title\n")
  in
  match parse_frontmatter source with
  | Ok _ -> Alcotest.fail "expected an invalid id to be rejected"
  | Error diags -> expect_error diags "TM101"

let () =
  let open Alcotest in
  run "Frontmatter"
    [ "valid_frontmatter", [ test_case "valid_frontmatter" `Quick test_valid_frontmatter ]
    ; "valid_id", [ test_case "valid_id" `Quick test_valid_id ]
    ; "parse_attribution_tree", [ test_case "parse_attribution_tree" `Quick test_parse_attribution_tree ]
    ; "parse_attribution_literal", [ test_case "parse_attribution_literal" `Quick test_parse_attribution_literal ]
    ; "parse_attribution_bad_id", [ test_case "parse_attribution_bad_id" `Quick test_parse_attribution_bad_id ]
    ; "valid_date_format", [ test_case "valid_date_format" `Quick test_valid_date_format ]
    ; "valid_date_invalid", [ test_case "valid_date_invalid" `Quick test_valid_date_invalid ]
    ; "duplicate_keys", [ test_case "duplicate_keys" `Quick test_duplicate_keys ]
    ; "unknown_keys", [ test_case "unknown_keys" `Quick test_unknown_keys ]
    ; "yaml_alias", [ test_case "yaml_alias" `Quick test_yaml_alias ]
    ; "first_fence_closes_frontmatter", [ test_case "first_fence_closes_frontmatter" `Quick test_first_fence_closes_frontmatter ]
    ; "missing_closing_delim", [ test_case "missing_closing_delim" `Quick test_missing_closing_delim ]
    ; "no_frontmatter", [ test_case "no_frontmatter" `Quick test_no_frontmatter ]
    ; "utf8_scalar_byte_mapping", [ test_case "utf8_scalar_byte_mapping" `Quick test_utf8_scalar_byte_mapping ]
    ; "multi_key_meta_then_taxon", [ test_case "multi_key_meta_then_taxon" `Quick test_multi_key_meta_then_taxon ]
    ; "tag_real_spans", [ test_case "tag_real_spans" `Quick test_tag_real_spans ]
    ; "non_scalar_key_rejected", [ test_case "non_scalar_key_rejected" `Quick test_non_scalar_key_rejected ]
    ; "promoted_meta_keys", [ test_case "promoted_meta_keys" `Quick test_promoted_meta_keys ]
    ; "promoted_meta_mixed", [ test_case "promoted_meta_mixed" `Quick test_promoted_meta_mixed ]
    ; "duplicate_meta_key", [ test_case "duplicate_meta_key" `Quick test_duplicate_meta_key ]
    ; "misspelled_meta_key", [ test_case "misspelled_meta_key" `Quick test_misspelled_meta_key ]
    ; "extension_key_never_warns", [ test_case "extension_key_never_warns" `Quick test_extension_key_never_warns ]
    ; "promoted_key_with_list_value", [ test_case "promoted_key_with_list_value" `Quick test_promoted_key_with_list_value ]
    ; "scalar_tags_accepted", [ test_case "scalar_tags_accepted" `Quick test_scalar_tags_accepted ]
    ; "scalar_text_is_preserved", [ test_case "scalar_text_is_preserved" `Quick test_scalar_text_is_preserved ]
    ; "id_key", [ test_case "id_key" `Quick test_id_key ]
    ; "invalid_id_rejected", [ test_case "invalid_id_rejected" `Quick test_invalid_id_rejected ]
    ]
