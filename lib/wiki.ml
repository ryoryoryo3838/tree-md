type kind = Link | Embed

type candidate = {
  kind : kind;
  target : string;
  alias : string option;
  whole_span : Span.t;
  inner_span : Span.t;
}

type shape =
  | Text_shape of Span.t
  | Code_shape of Span.t
  | Shortcut_shape of candidate
  | Ordinary_link_shape of Span.t

type wiki_meta = {
  wiki_kind : kind;
  wiki_body : string;
  whole_first_byte : int;
  whole_last_byte : int;
}

let wiki_meta_key : wiki_meta Cmarkit.Meta.key = Cmarkit.Meta.key ()

(* ── Source-aware resolver ── *)

let count_backslashes s before =
  let count = ref 0 in
  let i = ref (before - 1) in
  while !i >= 0 && s.[!i] = '\\' do
    incr count;
    decr i
  done;
  !count

let tag_wiki_label ref wiki_kind body whole_first whole_last =
  let info = { wiki_kind; wiki_body = body;
               whole_first_byte = whole_first;
               whole_last_byte = whole_last } in
  let meta = Cmarkit.Meta.add wiki_meta_key info (Cmarkit.Label.meta ref) in
  let key = Cmarkit.Label.key ref in
  let text_lines = Cmarkit.Label.text ref in
  let label = Cmarkit.Label.make ~meta ~key text_lines in
  Some label

let resolver source ctx =
  match ctx with
  | `Def _ -> Cmarkit.Label.default_resolver ctx
  | `Ref (_kind, ref, def) ->
    (match def with
     | Some _ -> Cmarkit.Label.default_resolver ctx
     | None ->
       let text = Source.text source in
       let ref_meta = Cmarkit.Label.meta ref in
       let tloc = Cmarkit.Meta.textloc ref_meta in
       if Cmarkit.Textloc.is_none tloc then
         Cmarkit.Label.default_resolver ctx
       else
         let fb = Cmarkit.Textloc.first_byte tloc in
         let lb = Cmarkit.Textloc.last_byte tloc in
         let src_len = String.length text in
         (* Check for ![[BODY]] first (longer prefix) *)
         if fb >= 3
            && text.[fb - 3] = '!'
            && text.[fb - 2] = '['
            && text.[fb - 1] = '[' then begin
           let outer_open = fb - 3 in
           let outer_close_start = lb + 1 in
           if outer_close_start + 1 < src_len
              && text.[outer_close_start] = ']'
              && text.[outer_close_start + 1] = ']' then begin
             let outer_close_end = outer_close_start + 2 in
             let bs_count = count_backslashes text outer_open in
             if bs_count mod 2 <> 0 then
               None
             else begin
               let left_is_bracket =
                 outer_open > 0 && text.[outer_open - 1] = '[' in
               let right_is_bracket =
                 outer_close_end < src_len
                 && text.[outer_close_end] = ']' in
               if left_is_bracket || right_is_bracket then
                 None
               else begin
                 let body = String.sub text fb (lb - fb + 1) in
                 tag_wiki_label ref Embed body outer_open (outer_close_end - 1)
               end
             end
           end else
             Cmarkit.Label.default_resolver ctx
         (* Check for [[BODY]] *)
         end else if fb >= 2 && text.[fb - 2] = '[' && text.[fb - 1] = '[' then begin
           let outer_open = fb - 2 in
           let outer_close_start = lb + 1 in
           if outer_close_start + 1 < src_len
              && text.[outer_close_start] = ']'
              && text.[outer_close_start + 1] = ']' then begin
             let outer_close_end = outer_close_start + 2 in
             let bs_count = count_backslashes text outer_open in
             if bs_count mod 2 <> 0 then
               None
             else begin
               let left_is_bracket =
                 outer_open > 0 && text.[outer_open - 1] = '[' in
               let right_is_bracket =
                 outer_close_end < src_len
                 && text.[outer_close_end] = ']' in
               if left_is_bracket || right_is_bracket then
                 None
               else if outer_open > 0 && text.[outer_open - 1] = ']' then
                 Cmarkit.Label.default_resolver ctx
               else begin
                 let body = String.sub text fb (lb - fb + 1) in
                 tag_wiki_label ref Link body outer_open (outer_close_end - 1)
               end
             end
           end else
             Cmarkit.Label.default_resolver ctx
         end else
           Cmarkit.Label.default_resolver ctx)

(* ── Shape collection for tests ── *)

let textloc_to_span source_path tloc =
  let fb = Cmarkit.Textloc.first_byte tloc in
  let lb = Cmarkit.Textloc.last_byte tloc in
  match Span.make ~path:source_path ~start_byte:fb ~end_byte:(lb + 1) with
  | Ok span -> span
  | Error _ ->
    { Span.path = source_path; start_byte = fb; end_byte = lb + 1 }

(* Split BODY on exactly one unescaped `|` using CommonMark backslash parity.
   An unescaped `|` has an even number of preceding backslashes.
   `\\|` is an escaped pipe (literal `|`) and does not delimit alias.
   Returns (target, alias_opt). If multiple unescaped `|` exist, the first one
   is treated as the delimiter and the rest become part of the alias body;
   alias validation (containing `|`) catches the error. *)
let parse_wiki_body body =
  let len = String.length body in
  let bs_count = ref 0 in
  let rec loop i =
    if i >= len then (body, None)
    else match body.[i] with
      | '\\' -> incr bs_count; loop (i + 1)
      | '|' when !bs_count mod 2 = 0 ->
        let target = String.sub body 0 i in
        let alias = String.sub body (i + 1) (len - i - 1) in
        (target, Some alias)
      | _ -> bs_count := 0; loop (i + 1)
  in
  loop 0

let valid_wiki_alias = function
  | None -> true
  | Some s -> String.length s > 0
              && not (String.contains s '[')
              && not (String.contains s ']')
              && not (String.contains s '|')

(* Count unescaped `|` delimiters in body. *)
let count_unescaped_pipes body =
  let len = String.length body in
  let count = ref 0 in
  let bs_count = ref 0 in
  for i = 0 to len - 1 do
    match body.[i] with
    | '\\' -> incr bs_count
    | '|' when !bs_count mod 2 = 0 -> incr count; bs_count := 0
    | _ -> bs_count := 0
  done;
  !count

let wiki_diagnostics body source_path info =
  let span =
    match Span.make ~path:source_path
            ~start_byte:info.whole_first_byte
            ~end_byte:(info.whole_last_byte + 1) with
    | Ok s -> s
    | Error _ ->
      { Span.path = source_path;
        start_byte = info.whole_first_byte;
        end_byte = info.whole_last_byte + 1 }
  in
  let pipe_count = count_unescaped_pipes body in
  if pipe_count > 1 then
    [Diagnostic.make TM105 (Span.Source_span span)
       "multiple unescaped pipes in wiki body"]
  else
    let target, alias = parse_wiki_body body in
    if not (Metadata.valid_id target) then
      [Diagnostic.make TM105 (Span.Source_span span)
         ("invalid wiki target: \"" ^ target ^ "\"")]
    else if not (valid_wiki_alias alias) then
      let msg =
        match alias with
        | Some "" -> "empty wiki alias"
        | Some a when String.contains a '[' || String.contains a ']' ->
          "wiki alias contains brackets"
        | _ -> "invalid wiki alias"
      in
      [Diagnostic.make TM105 (Span.Source_span span) msg]
    else
      []

(* ── Inline / block walker with paragraph-span guard ── *)

(* Check that whole_span is contained within paragraph_span.
   If paragraph_span is None, skip the check (e.g. heading, blockquote). *)
let within_paragraph paragraph_span whole_span =
  match paragraph_span with
  | None -> true
  | Some { Span.start_byte = p_start; end_byte = p_end; _ } ->
    whole_span.Span.start_byte >= p_start
    && whole_span.Span.end_byte <= p_end

let rec collect_inlines source_path paragraph_span inline acc_diags acc_shapes =
  match inline with
  | Cmarkit.Inline.Inlines (inlines, _meta) ->
    List.fold_left (fun (diags, shapes) i ->
      collect_inlines source_path paragraph_span i diags shapes
    ) (acc_diags, acc_shapes) inlines
  | Cmarkit.Inline.Text (_text, meta) ->
    let tloc = Cmarkit.Meta.textloc meta in
    let span = textloc_to_span source_path tloc in
    (acc_diags, Text_shape span :: acc_shapes)
  | Cmarkit.Inline.Code_span (_cs, meta) ->
    let tloc = Cmarkit.Meta.textloc meta in
    let span = textloc_to_span source_path tloc in
    (acc_diags, Code_shape span :: acc_shapes)
  | Cmarkit.Inline.Link (link, meta) ->
    (match Cmarkit.Inline.Link.reference link with
     | `Ref (`Shortcut, source_label, def_label) ->
       let def_meta = Cmarkit.Label.meta def_label in
       (match Cmarkit.Meta.find wiki_meta_key def_meta with
        | Some info ->
          let source_meta = Cmarkit.Label.meta source_label in
          let tloc = Cmarkit.Meta.textloc source_meta in
          let inner_span = textloc_to_span source_path tloc in
          let whole_span =
            match Span.make ~path:source_path
                    ~start_byte:info.whole_first_byte
                    ~end_byte:(info.whole_last_byte + 1) with
            | Ok s -> s
            | Error _ -> inner_span
          in
          if not (within_paragraph paragraph_span whole_span) then begin
            (* Guard 5: wiki envelope crosses paragraph boundary *)
            let link_tloc = Cmarkit.Meta.textloc meta in
            let link_span = textloc_to_span source_path link_tloc in
            (acc_diags, Ordinary_link_shape link_span :: acc_shapes)
          end else begin
            let body = info.wiki_body in
            let diags = wiki_diagnostics body source_path info in
            if diags = [] then begin
              let target, alias = parse_wiki_body body in
              let candidate = { kind = info.wiki_kind; target; alias;
                                whole_span; inner_span } in
              (acc_diags @ diags, Shortcut_shape candidate :: acc_shapes)
            end else begin
              let link_tloc = Cmarkit.Meta.textloc meta in
              let link_span = textloc_to_span source_path link_tloc in
              (acc_diags @ diags, Ordinary_link_shape link_span :: acc_shapes)
            end
          end
        | None ->
          let link_tloc = Cmarkit.Meta.textloc meta in
          let link_span = textloc_to_span source_path link_tloc in
          (acc_diags, Ordinary_link_shape link_span :: acc_shapes))
     | _ ->
       let link_tloc = Cmarkit.Meta.textloc meta in
       let link_span = textloc_to_span source_path link_tloc in
       (acc_diags, Ordinary_link_shape link_span :: acc_shapes))
  | Cmarkit.Inline.Emphasis (em, _meta) ->
    let inner = Cmarkit.Inline.Emphasis.inline em in
    collect_inlines source_path paragraph_span inner acc_diags acc_shapes
  | Cmarkit.Inline.Strong_emphasis (em, _meta) ->
    let inner = Cmarkit.Inline.Emphasis.inline em in
    collect_inlines source_path paragraph_span inner acc_diags acc_shapes
  (* Explicit fallback for supported Cmarkit inline types not relevant to
     Task 3 wiki characterization. Images, breaks, autolinks, raw HTML,
     math spans, and strikethrough are intentionally skipped: their presence
     in test fixtures would produce incomplete shape lists, and the caller
     should either handle shapes accordingly or restrict test input to the
     characterization table. *)
  | _ -> (acc_diags, acc_shapes)

let rec collect_blocks source_path block acc_diags acc_shapes =
  match block with
  | Cmarkit.Block.Blocks (blocks, _meta) ->
    List.fold_left (fun (diags, shapes) b ->
      collect_blocks source_path b diags shapes
    ) (acc_diags, acc_shapes) blocks
  | Cmarkit.Block.Paragraph (p, p_meta) ->
    let p_span =
      let tloc = Cmarkit.Meta.textloc p_meta in
      if Cmarkit.Textloc.is_none tloc then None
      else Some (textloc_to_span source_path tloc)
    in
    let inline = Cmarkit.Block.Paragraph.inline p in
    collect_inlines source_path p_span inline acc_diags acc_shapes
  | Cmarkit.Block.Heading (h, h_meta) ->
    let h_span =
      let tloc = Cmarkit.Meta.textloc h_meta in
      if Cmarkit.Textloc.is_none tloc then None
      else Some (textloc_to_span source_path tloc)
    in
    let inline = Cmarkit.Block.Heading.inline h in
    collect_inlines source_path h_span inline acc_diags acc_shapes
  | Cmarkit.Block.Block_quote (bq, _meta) ->
    let inner = Cmarkit.Block.Block_quote.block bq in
    collect_blocks source_path inner acc_diags acc_shapes
  | Cmarkit.Block.List (l, _meta) ->
    let items = Cmarkit.Block.List'.items l in
    List.fold_left (fun (diags, shapes) item_node ->
      let item, _meta = item_node in
      let inner = Cmarkit.Block.List_item.block item in
      collect_blocks source_path inner diags shapes
    ) (acc_diags, acc_shapes) items
  | _ -> (acc_diags, acc_shapes)

let shapes_for_test source text =
  let doc =
    Cmarkit.Doc.of_string ~locs:true ~resolver:(resolver source) text
  in
  let block = Cmarkit.Doc.block doc in
  let (diags, shapes_rev) = collect_blocks (Source.path source) block [] [] in
  Ok (List.rev shapes_rev, List.rev diags)

let validate_wiki_body ~source_path ~info =
  let body = info.wiki_body in
  let diags = wiki_diagnostics body source_path info in
  if diags = [] then begin
    let target, alias = parse_wiki_body body in
    Ok (target, alias)
  end else
    Error diags
