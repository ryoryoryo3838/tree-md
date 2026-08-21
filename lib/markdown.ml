(* Convert Cmarkit's inclusive Textloc to half-open Span.t *)
let textloc_to_span source_path base_byte tloc =
  let fb = Cmarkit.Textloc.first_byte tloc + base_byte in
  let lb = Cmarkit.Textloc.last_byte tloc + base_byte in
  match Span.make ~path:source_path ~start_byte:fb ~end_byte:(lb + 1) with
  | Ok span -> span
  | Error _ ->
    { Span.path = source_path; start_byte = fb; end_byte = lb + 1 }

let meta_span source_path base_byte meta =
  let tloc = Cmarkit.Meta.textloc meta in
  if Cmarkit.Textloc.is_none tloc then
    { Span.path = source_path; start_byte = 0; end_byte = 0 }
  else
    textloc_to_span source_path base_byte tloc

let node_text (n : string Cmarkit.node) : string = fst n

(* Make a span from raw byte positions *)
let make_span source_path base_byte first last =
  match Span.make ~path:source_path
          ~start_byte:(first + base_byte)
          ~end_byte:(last + 1 + base_byte) with
  | Ok s -> s
  | Error _ ->
    { Span.path = source_path;
      start_byte = first + base_byte;
      end_byte = last + 1 + base_byte }

(* Extract destination string from link definition *)
let link_dest (def : Cmarkit.Link_definition.t) : string =
  match Cmarkit.Link_definition.dest def with
  | Some dest_node -> node_text dest_node
  | None -> ""

(* Extract title string from link definition *)
let link_title (def : Cmarkit.Link_definition.t) : string option =
  match Cmarkit.Link_definition.title def with
  | Some lines ->
    let s = String.concat " " (List.map (fun (str, _layout) -> str) lines) in
    if s = "" then None else Some s
  | None -> None

(* Construct an empty link definition for unresolved references *)
let empty_link_def () =
  Cmarkit.Link_definition.make ()

(* Resolve a reference link against doc defs *)
(* A footnote reference is an ordinary reference link whose definition happens
   to be a footnote. Its number is not known until the whole document has been
   walked, so lowering records the label and leaves the number at zero. *)
let footnote_label defs link =
  match Cmarkit.Inline.Link.reference_definition defs link with
  | Some (Cmarkit.Block.Footnote.Def (footnote, _meta)) ->
    Some (Cmarkit.Label.key (Cmarkit.Block.Footnote.label footnote))
  | _ -> None

(* Obsidian embeds an attachment the same way it embeds a note: `![[x.png]]`.
   Which one is meant is settled by the extension, because an image is not a
   tree and has no address to transclude. Obsidian's size syntax,
   `![[x.png|300]]`, gives the width. *)
let image_extensions =
  [ ".png"; ".jpg"; ".jpeg"; ".gif"; ".svg"; ".webp"; ".bmp"; ".avif"; ".ico" ]

let is_image_target target =
  let lowered = String.lowercase_ascii target in
  List.exists
    (fun ext ->
      let n = String.length lowered and e = String.length ext in
      n > e && String.sub lowered (n - e) e = ext)
    image_extensions

let all_digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '9') s

let resolve_link_ref defs link =
  match Cmarkit.Inline.Link.reference_definition defs link with
  | Some (Cmarkit.Link_definition.Def def_node) ->
    Some (fst def_node)
  | _ -> None

(* Validate TeX payload: reject empty and unbalanced braces *)
let balanced_braces tex =
  let depth = ref 0 in
  let len = String.length tex in
  let rec loop i =
    if i >= len then !depth = 0
    else
      let c = tex.[i] in
      match c with
      | '{' -> incr depth; loop (i + 1)
      | '}' -> decr depth; if !depth < 0 then false else loop (i + 1)
      | '\\' when i + 1 < len -> loop (i + 2)
      | _ -> loop (i + 1)
  in
  loop 0

let rec lower_inlines source_path base_byte defs inline acc_inlines acc_diags =
  match inline with
  | Cmarkit.Inline.Inlines (inlines, _meta) ->
    List.fold_left (fun (ins, diags) i ->
      lower_inlines source_path base_byte defs i ins diags
    ) (acc_inlines, acc_diags) inlines

  | Cmarkit.Inline.Text (_text, meta) ->
    let span = meta_span source_path base_byte meta in
    let text = node_text (_text, meta) in
    let node = Ir.Text text in
    if text = "" then
      (acc_inlines, acc_diags)
    else
      (({ node; span } : Ir.inline) :: acc_inlines, acc_diags)

  | Cmarkit.Inline.Code_span (cs, meta) ->
    let span = meta_span source_path base_byte meta in
    let code = Cmarkit.Inline.Code_span.code cs in
    let node = Ir.Code code in
    (({ node; span } : Ir.inline) :: acc_inlines, acc_diags)

  | Cmarkit.Inline.Emphasis (em, meta) ->
    let span = meta_span source_path base_byte meta in
    let inner = Cmarkit.Inline.Emphasis.inline em in
    let children, diags = lower_inlines source_path base_byte defs inner [] [] in
    let node = Ir.Emphasis (List.rev children) in
    (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)

  | Cmarkit.Inline.Strong_emphasis (em, meta) ->
    let span = meta_span source_path base_byte meta in
    let inner = Cmarkit.Inline.Emphasis.inline em in
    let children, diags = lower_inlines source_path base_byte defs inner [] [] in
    let node = Ir.Strong (List.rev children) in
    (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)

  | Cmarkit.Inline.Link (link, meta) ->
    let span = meta_span source_path base_byte meta in
    let link_text = Cmarkit.Inline.Link.text link in
    let children, diags = lower_inlines source_path base_byte defs link_text [] [] in
    begin match Cmarkit.Inline.Link.reference link with
    | `Ref (`Shortcut, _source_label, def_label) ->
      let def_meta = Cmarkit.Label.meta def_label in
      (match Cmarkit.Meta.find Wiki.wiki_meta_key def_meta with
       | Some info ->
         let ws = make_span source_path base_byte
                    info.Wiki.whole_first_byte
                    info.Wiki.whole_last_byte in
         (match Wiki.validate_wiki_body ~source_path ~info with
          | Ok (target, alias) ->
            begin match info.Wiki.wiki_kind with
            | Wiki.Link ->
              let node = Ir.Wiki_link { target; alias } in
              (({ node; span = ws } : Ir.inline) :: acc_inlines, acc_diags @ diags)
            | Wiki.Embed when is_image_target target ->
              (* The alt text is the file name, which is what Obsidian shows
                 when the attachment is missing. A numeric alias is a width. *)
              let alt = [ { Ir.node = Ir.Text target; span = ws } ] in
              let width =
                match alias with
                | Some value when all_digits value -> Some value
                | _ -> None
              in
              let alt =
                match alias with
                | Some text when not (all_digits text) ->
                  [ { Ir.node = Ir.Text text; span = ws } ]
                | _ -> alt
              in
              let node =
                Ir.Image { alt; destination = Safe_uri.percent_encode target;
                           asset_path = target; width; title = None }
              in
              (({ node; span = ws } : Ir.inline) :: acc_inlines, acc_diags @ diags)
            | Wiki.Embed ->
              let node = Ir.Wiki_embed target in
              (({ node; span = ws } : Ir.inline) :: acc_inlines, acc_diags @ diags)
            end
          | Error wiki_diags ->
            (acc_inlines, acc_diags @ diags @ wiki_diags))
       | None -> (
         match footnote_label defs link with
         | Some label ->
           let node = Ir.Footnote_ref { label; number = 0 } in
           (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)
         | None ->
         match resolve_link_ref defs link with
          | Some def ->
            let dest = link_dest def in
            let title = link_title def in
            (match Safe_uri.validate Safe_uri.Link span dest with
             | Ok validated_dest ->
               let node = Ir.Link { label = List.rev children; destination = validated_dest.Safe_uri.written; title } in
               (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)
             | Error d ->
               (acc_inlines, d :: acc_diags @ diags))
          | None ->
            (* Unresolved link: no destination, still emit node with empty dest *)
            let node = Ir.Link { label = List.rev children; destination = ""; title = None } in
            (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags))
      )
    | `Ref _ ->
      (match resolve_link_ref defs link with
       | Some def ->
         let dest = link_dest def in
         let title = link_title def in
         (match Safe_uri.validate Safe_uri.Link span dest with
          | Ok validated_dest ->
            let node = Ir.Link { label = List.rev children; destination = validated_dest.Safe_uri.written; title } in
            (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)
          | Error d ->
            (acc_inlines, d :: acc_diags @ diags))
       | None ->
         let node = Ir.Link { label = List.rev children; destination = ""; title = None } in
         (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags))
    | `Inline def_node ->
      let def = fst def_node in
      let dest = link_dest def in
      let title = link_title def in
      (match Safe_uri.validate Safe_uri.Link span dest with
       | Ok validated_dest ->
         let node = Ir.Link { label = List.rev children; destination = validated_dest.Safe_uri.written; title } in
         (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)
       | Error d ->
         (acc_inlines, d :: acc_diags @ diags))
    end

  | Cmarkit.Inline.Image (link, meta) ->
    let span = meta_span source_path base_byte meta in
    let alt_inline = Cmarkit.Inline.Link.text link in
    let alt_children, diags = lower_inlines source_path base_byte defs alt_inline [] [] in
    let def =
      match Cmarkit.Inline.Link.reference link with
      | `Inline def_node -> fst def_node
      | `Ref _ ->
        (match resolve_link_ref defs link with
         | Some def -> def
         | None -> empty_link_def ())
    in
    let dest = link_dest def in
    let title = link_title def in
    (match Safe_uri.validate Safe_uri.Image span dest with
     | Ok validated_dest ->
       let node =
         Ir.Image
           { alt = List.rev alt_children;
             destination = validated_dest.Safe_uri.encoded;
             asset_path = validated_dest.Safe_uri.written;
             width = None;
             title }
       in
       (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)
     | Error d ->
       (acc_inlines, d :: acc_diags @ diags))

  | Cmarkit.Inline.Autolink (al, meta) ->
    let span = meta_span source_path base_byte meta in
    let url = node_text (Cmarkit.Inline.Autolink.link al) in
    let dest = if Cmarkit.Inline.Autolink.is_email al then "mailto:" ^ url else url in
    (match Safe_uri.validate Safe_uri.Link span dest with
     | Ok validated_dest ->
       let label_node = Ir.Text url in
       let node = Ir.Link { label = [{ node = label_node; span }]; destination = validated_dest.Safe_uri.written; title = None } in
       (({ node; span } : Ir.inline) :: acc_inlines, acc_diags)
     | Error d ->
       (acc_inlines, d :: acc_diags))

  | Cmarkit.Inline.Break (br, meta) ->
    let span = meta_span source_path base_byte meta in
    let node = match Cmarkit.Inline.Break.type' br with
      | `Hard -> Ir.Hard_break
      | `Soft -> Ir.Soft_break
    in
    (({ node; span } : Ir.inline) :: acc_inlines, acc_diags)

  | Cmarkit.Inline.Ext_math_span (ms, meta) ->
    let span = meta_span source_path base_byte meta in
    let tex = Cmarkit.Inline.Math_span.tex ms in
    let display = Cmarkit.Inline.Math_span.display ms in
    let trimmed = String.trim tex in
    if trimmed = "" then
      let diag = Diagnostic.make TM107 (Span.Source_span span)
        "empty math expression" in
      (acc_inlines, diag :: acc_diags)
    else if not (balanced_braces tex) then
      let diag = Diagnostic.make TM107 (Span.Source_span span)
        "unbalanced braces in math expression" in
      (acc_inlines, diag :: acc_diags)
    else
      let node = Ir.Math { tex = trimmed; display } in
      (({ node; span } : Ir.inline) :: acc_inlines, acc_diags)

  | Cmarkit.Inline.Raw_html (html, meta) ->
    let html_str =
      List.map Cmarkit.Block_line.tight_to_string html
      |> String.concat "" in
    let trimmed = String.trim html_str in
    if String.length trimmed >= 7
       && String.sub trimmed 0 4 = "<!--"
       && String.sub trimmed (String.length trimmed - 3) 3 = "-->"
    then
      (acc_inlines, acc_diags)  (* discard HTML comments *)
    else begin
      let span = meta_span source_path base_byte meta in
      let diag = Diagnostic.make TM102 (Span.Source_span span)
        "raw HTML is not supported" in
      (acc_inlines, diag :: acc_diags)
    end

  | Cmarkit.Inline.Ext_strikethrough (st, meta) ->
    let span = meta_span source_path base_byte meta in
    let inner = Cmarkit.Inline.Strikethrough.inline st in
    let children, diags =
      lower_inlines source_path base_byte defs inner [] [] in
    let node = Ir.Strikethrough (List.rev children) in
    (({ node; span } : Ir.inline) :: acc_inlines, acc_diags @ diags)

  (* Any unrecognized extension inline: reject with TM102.
     When a span is available from the inline's metadata, use it;
     otherwise fall back to No_location. *)
  | _ ->
    let diag = Diagnostic.make TM102 Span.No_location
      "unsupported Markdown extension" in
    (acc_inlines, diag :: acc_diags)

(* Remove wiki envelope brackets from Text nodes.
   Cmarkit merges the outermost `[`/`]` of a wiki shortcut envelope into
   adjacent Text runs (e.g. `Plain wiki: [[manual]].` lowers to
   Text "Plain wiki: [" + Wiki_link + Text "]."), so a Text node may only
   partially overlap a wiki whole-span. Fully contained Text nodes (the
   bare `[` and `]` wrappers) are dropped; partially overlapping Text
   nodes are split and only the bracket bytes that fall inside a wiki
   whole-span are stripped. *)
let filter_wiki_wrappers inlines =
  (* An image is here because `![[x.png]]` lowers to one, and the `!` and the
     brackets Cmarkit left beside it have to go the same way they do for a
     link or a note embed. An ordinary `![alt](url)` has no sibling text inside
     its own span, so counting it changes nothing. *)
  let wiki_spans = List.filter_map (fun i ->
    match i.Ir.node with
    | Ir.Wiki_link _ | Ir.Wiki_embed _ | Ir.Image _ -> Some i.Ir.span
    | _ -> None
  ) inlines in
  let is_within_wiki span =
    List.exists (fun ws ->
      span.Span.start_byte >= ws.Span.start_byte
      && span.Span.end_byte <= ws.Span.end_byte
    ) wiki_spans
  in
  let in_wiki_span byte =
    List.exists (fun ws ->
      byte >= ws.Span.start_byte && byte < ws.Span.end_byte
    ) wiki_spans
  in
  let strip_envelope (i : Ir.inline) =
    match i.Ir.node with
    | Ir.Text s ->
      let span = i.Ir.span in
      let len = String.length s in
      (* Keep every byte except `[`/`]` bytes that fall inside a wiki
         whole-span: those are the envelope brackets Cmarkit merged into
         the adjacent text run. *)
      let keep = Array.make len true in
      for k = 0 to len - 1 do
        if in_wiki_span (span.Span.start_byte + k)
           && (s.[k] = '[' || s.[k] = ']')
        then keep.(k) <- false
      done;
      (* Split into runs of kept bytes *)
      let runs = ref [] in
      let pos = ref 0 in
      while !pos < len do
        if keep.(!pos) then begin
          let start = !pos in
          while !pos < len && keep.(!pos) do incr pos done;
          runs := (start, !pos) :: !runs
        end else
          incr pos
      done;
      List.rev_map (fun (start, stop) ->
        let text = String.sub s start (stop - start) in
        let nspan =
          match Span.make ~path:span.Span.path
                  ~start_byte:(span.Span.start_byte + start)
                  ~end_byte:(span.Span.start_byte + stop) with
          | Ok sp -> sp
          | Error _ -> span
        in
        { Ir.node = Ir.Text text; span = nspan }
      ) !runs
    | _ -> [i]
  in
  List.concat_map (fun i ->
    match i.Ir.node with
    | Ir.Text _ ->
      if is_within_wiki i.Ir.span then []
      else strip_envelope i
    | _ -> [i]
  ) inlines

(* Walk block-level AST to extract all inlines *)
let rec extract_inlines source_path base_byte defs block acc_inlines acc_diags =
  match block with
  | Cmarkit.Block.Blocks (blocks, _meta) ->
    List.fold_left (fun (ins, diags) b ->
      extract_inlines source_path base_byte defs b ins diags
    ) (acc_inlines, acc_diags) blocks

  | Cmarkit.Block.Paragraph (p, _meta) ->
    let inline = Cmarkit.Block.Paragraph.inline p in
    lower_inlines source_path base_byte defs inline acc_inlines acc_diags

  | Cmarkit.Block.Heading (h, _meta) ->
    let inline = Cmarkit.Block.Heading.inline h in
    lower_inlines source_path base_byte defs inline acc_inlines acc_diags

  | Cmarkit.Block.Block_quote (bq, _meta) ->
    let inner = Cmarkit.Block.Block_quote.block bq in
    extract_inlines source_path base_byte defs inner acc_inlines acc_diags

  | Cmarkit.Block.List (l, _meta) ->
    let items = Cmarkit.Block.List'.items l in
    List.fold_left (fun (ins, diags) item_node ->
      let item, _meta = item_node in
      let inner = Cmarkit.Block.List_item.block item in
      extract_inlines source_path base_byte defs inner ins diags
    ) (acc_inlines, acc_diags) items

  | _ ->
    (acc_inlines, acc_diags)

(* parse_inlines: parse the given Markdown string as inline content.
   [source] is used for path and span resolution.
   [text] is the masked Markdown string.
   [base_byte] is an offset added to all byte positions in the result,
   used when the text is a substring of the original source (e.g. YAML
   scalar values within front matter). *)
(* ── Obsidian inline marks ──

   `==highlight==` and `%%comment%%` are Obsidian's, not CommonMark's, so
   cmarkit hands them over as ordinary text. They are recognised over the
   inline *list* rather than inside a single text node, because anything
   cmarkit does understand — a code span, math, a link — splits the run they
   delimit. A delimiter inside a code span is therefore never seen, which is
   the behaviour we want. *)

let find_delimiter delimiter inlines (from_index, from_offset) =
  let width = String.length delimiter in
  let rec loop index = function
    | [] -> None
    | ({ Ir.node = Ir.Text s; _ } : Ir.inline) :: rest when index >= from_index ->
      let start = if index = from_index then from_offset else 0 in
      let rec scan j =
        if j + width > String.length s then None
        else if String.sub s j width = delimiter then Some (index, j)
        else scan (j + 1)
      in
      (match scan start with Some found -> Some found | None -> loop (index + 1) rest)
    | _ :: rest -> loop (index + 1) rest
  in
  loop 0 inlines

let inlines_before inlines (stop_index, stop_offset) =
  let rec loop index acc = function
    | [] -> List.rev acc
    | (item : Ir.inline) :: rest ->
      if index < stop_index then loop (index + 1) (item :: acc) rest
      else
        (match item.Ir.node with
         | Ir.Text s when stop_offset > 0 ->
           List.rev ({ item with Ir.node = Ir.Text (String.sub s 0 stop_offset) } :: acc)
         | _ -> List.rev acc)
  in
  loop 0 [] inlines

let inlines_after inlines (start_index, start_offset) =
  let rec loop index = function
    | [] -> []
    | (item : Ir.inline) :: rest ->
      if index < start_index then loop (index + 1) rest
      else
        (match item.Ir.node with
         | Ir.Text s ->
           let tail = String.sub s start_offset (String.length s - start_offset) in
           if tail = "" then rest
           else { item with Ir.node = Ir.Text tail } :: rest
         | _ -> item :: rest)
  in
  loop 0 inlines

let inlines_between inlines (start_index, start_offset) (stop_index, stop_offset) =
  let rec loop index acc = function
    | [] -> List.rev acc
    | (item : Ir.inline) :: rest ->
      if index < start_index then loop (index + 1) acc rest
      else if index > stop_index then List.rev acc
      else
        let acc =
          match item.Ir.node with
          | Ir.Text s ->
            let from = if index = start_index then start_offset else 0 in
            let upto = if index = stop_index then stop_offset else String.length s in
            if upto > from then
              { item with Ir.node = Ir.Text (String.sub s from (upto - from)) } :: acc
            else acc
          | _ -> item :: acc
        in
        loop (index + 1) acc rest
  in
  loop 0 [] inlines

(* [build] turns the delimited run into what replaces it: [None] drops it,
   which is what a comment is. An unclosed delimiter stays literal text. *)
let rec delimited_pass ~delimiter ~build inlines =
  match find_delimiter delimiter inlines (0, 0) with
  | None -> inlines
  | Some (open_index, open_offset) -> (
    let after_open = (open_index, open_offset + String.length delimiter) in
    match find_delimiter delimiter inlines after_open with
    | None -> inlines
    | Some (close_index, close_offset) ->
      let inner = inlines_between inlines after_open (close_index, close_offset) in
      if inner = [] then
        (* `====` and `%%%%` delimit nothing; leaving them literal is closer to
           what was meant than emitting an empty element. *)
        inlines
      else
        let span =
          match List.nth_opt inlines open_index with
          | Some item -> item.Ir.span
          | None -> (List.hd inlines).Ir.span
        in
        let rest =
          inlines_after inlines
            (close_index, close_offset + String.length delimiter)
        in
        inlines_before inlines (open_index, open_offset)
        @ (match build inner span with None -> [] | Some node -> [ node ])
        @ delimited_pass ~delimiter ~build rest)

let obsidian_marks inlines =
  let inlines =
    delimited_pass ~delimiter:"%%"
      ~build:(fun _inner _span -> None)
      inlines
  in
  delimited_pass ~delimiter:"=="
    ~build:(fun inner span -> Some { Ir.node = Ir.Highlight inner; span })
    inlines

(* Apply [f] to every inline list in the document, outermost first. *)
let rec map_inlines f (inlines : Ir.inline list) =
  List.map
    (fun (item : Ir.inline) ->
      match item.Ir.node with
      | Ir.Emphasis inner -> { item with Ir.node = Ir.Emphasis (map_inlines f (f inner)) }
      | Ir.Strong inner -> { item with Ir.node = Ir.Strong (map_inlines f (f inner)) }
      | Ir.Strikethrough inner ->
        { item with Ir.node = Ir.Strikethrough (map_inlines f (f inner)) }
      | Ir.Highlight inner ->
        { item with Ir.node = Ir.Highlight (map_inlines f (f inner)) }
      | Ir.Link link ->
        { item with
          Ir.node = Ir.Link { link with Ir.label = map_inlines f (f link.Ir.label) } }
      | Ir.Image image ->
        { item with
          Ir.node = Ir.Image { image with Ir.alt = map_inlines f (f image.Ir.alt) } }
      | Ir.Text _ | Ir.Code _ | Ir.Wiki_link _ | Ir.Wiki_embed _ | Ir.Math _
      | Ir.Footnote_ref _ | Ir.Hard_break | Ir.Soft_break -> item)
    inlines

let inlines_are_blank inlines =
  List.for_all
    (fun (item : Ir.inline) ->
      match item.Ir.node with
      | Ir.Text s -> String.trim s = ""
      | Ir.Soft_break | Ir.Hard_break -> true
      | _ -> false)
    inlines

let rec map_block_inlines f (block : Ir.block) =
  let apply inlines = map_inlines f (f inlines) in
  match block.Ir.bnode with
  | Ir.Paragraph inlines ->
    { block with Ir.bnode = Ir.Paragraph (apply inlines) }
  | Ir.Heading { level; title } ->
    { block with Ir.bnode = Ir.Heading { level; title = apply title } }
  | Ir.Blockquote blocks ->
    { block with Ir.bnode = Ir.Blockquote (map_blocks_inlines f blocks) }
  | Ir.Callout { kind; folded; title; body } ->
    { block with
      Ir.bnode =
        Ir.Callout
          { kind; folded; title = apply title; body = map_blocks_inlines f body } }
  | Ir.List { kind; tight; items } ->
    { block with
      Ir.bnode =
        Ir.List
          { kind; tight;
            items =
              List.map
                (fun (item : Ir.list_item) ->
                  { item with
                    Ir.item_blocks = map_blocks_inlines f item.Ir.item_blocks })
                items } }
  | Ir.Table { alignment; header; rows } ->
    { block with
      Ir.bnode =
        Ir.Table
          { alignment;
            header = Option.map (List.map apply) header;
            rows = List.map (List.map apply) rows } }
  | Ir.Footnote_def { label; body } ->
    { block with
      Ir.bnode = Ir.Footnote_def { label; body = map_blocks_inlines f body } }
  | Ir.Footnotes entries ->
    { block with
      Ir.bnode =
        Ir.Footnotes
          (List.map (fun (n, body) -> (n, map_blocks_inlines f body)) entries) }
  | Ir.Code_block _ | Ir.Thematic_break | Ir.Subtree_directive _
  | Ir.Subtree_open _ | Ir.Subtree_close _ | Ir.Block_embed _
  | Ir.Display_math _ -> block

(* A paragraph that held nothing but a comment leaves no `\p{}` behind, the
   same bargain a paragraph holding nothing but a block anchor already
   strikes. *)
and map_blocks_inlines f blocks =
  List.filter_map
    (fun block ->
      let block = map_block_inlines f block in
      match block.Ir.bnode with
      | Ir.Paragraph inlines when inlines_are_blank inlines -> None
      | _ -> Some block)
    blocks

let parse_inlines source text ~base_byte =
  let doc =
    Cmarkit.Doc.of_string ~locs:true ~strict:false
      ~resolver:(Wiki.resolver source) text
  in
  let block = Cmarkit.Doc.block doc in
  let defs = Cmarkit.Doc.defs doc in
  let path = Source.path source in
  let inlines, diags = extract_inlines path base_byte defs block [] [] in
  let filtered = filter_wiki_wrappers inlines in
  let sorted_inlines =
    map_inlines obsidian_marks (obsidian_marks (List.rev filtered))
  in
  let sorted_diags = List.rev diags in
  Diagnostic.gate sorted_inlines sorted_diags

(* ── Block lowering ── *)

let valid_lang_token s =
  let len = String.length s in
  if len = 0 then false
  else
    let first = s.[0] in
    if not ((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z')
            || (first >= '0' && first <= '9'))
    then false
    else
      let rec loop i =
        if i >= len then true
        else
          let c = s.[i] in
          match c with
          | 'A'..'Z' | 'a'..'z' | '0'..'9' | '_' | '+' | '.' | '-' -> loop (i + 1)
          | _ -> false
      in
      loop 1

let code_info_of_fence source_path base_byte info_node =
  let info_text = node_text info_node in
  let trimmed = String.trim info_text in
  let info_meta = snd info_node in
  if trimmed = "" then
    Ok Ir.No_info
  else if trimmed = "math" then
    let span = meta_span source_path base_byte info_meta in
    Error (Diagnostic.make TM102 (Span.Source_span span)
             "fenced math blocks are not supported; use $$...$$ for display math")
  else
    let tokens = String.split_on_char ' ' trimmed
                 |> List.filter (fun s -> s <> "") in
    match tokens with
    | [] -> Ok Ir.No_info
    | [tok] ->
      if valid_lang_token tok then
        Ok (Ir.Language tok)
      else
        let span = meta_span source_path base_byte info_meta in
        Error (Diagnostic.make TM102 (Span.Source_span span)
                 ("invalid language token: \"" ^ tok ^ "\""))
    | _ ->
      let span = meta_span source_path base_byte info_meta in
      Error (Diagnostic.make TM102 (Span.Source_span span)
               "multi-token fenced code info is not supported")

let code_block_lines lines =
  let strings = List.map (fun (s, _layout) -> s) lines in
  String.concat "\n" strings

(* ── Structural directives written as HTML comments ──

   Markdown headings can only express a *titled* section that runs until the
   next heading of the same or a lower level.  Two Forester shapes have no
   heading equivalent: a subtree with no \title, and returning to a parent's
   body after a child subtree has ended.  Three comment forms cover them:

     <!-- subtree: ID -->  attach ID to the heading that follows
     <!-- h3 -->           open an untitled level-3 subtree
     <!-- h3:ID -->        open an untitled level-3 subtree named ID
     <!-- /h3 -->          close every open subtree at level 3 or deeper

   The level is written on both the opening and the closing form so that a
   directive-delimited subtree slots into the same level stack that headings
   already build; nothing can cross, and a closing directive is only ever
   needed when you want to write more of the parent's body. *)

type directive =
  | Dir_annotate of string
  | Dir_open of { level : int; id : string option }
  | Dir_close of int

let is_comment s =
  String.length s >= 7
  && String.sub s 0 4 = "<!--"
  && String.sub s (String.length s - 3) 3 = "-->"

let comment_inner s = String.trim (String.sub s 4 (String.length s - 7))

(* The leading run of characters that is neither whitespace nor the ':' that
   introduces an identifier. *)
let leading_token s =
  let n = String.length s in
  let rec loop i =
    if i >= n then i
    else match s.[i] with ' ' | '\t' | ':' -> i | _ -> loop (i + 1)
  in
  String.sub s 0 (loop 0)

let all_digits_after_first t =
  let ok = ref true in
  String.iteri (fun i c -> if i > 0 && not (c >= '0' && c <= '9') then ok := false) t;
  !ok

(* "h3" -> Some 3.  Deliberately strict: int_of_string would also accept
   "0x2" and "3_0". *)
let level_of_token t =
  if String.length t >= 2 && t.[0] = 'h' && all_digits_after_first t then
    int_of_string_opt (String.sub t 1 (String.length t - 1))
  else None

(* Close enough to a directive that a typo must be reported rather than
   silently discarded along with ordinary comments. *)
let looks_like_level_token t =
  String.length t >= 2
  && (t.[0] = 'h' || t.[0] = 'H')
  && all_digits_after_first t

(* [Ok None] is an ordinary comment, to be discarded.  [Error msg] is a
   comment that names a directive but does not parse; discarding those would
   change the shape of the emitted tree with nothing to show for it. *)
let parse_directive inner =
  let s = String.trim inner in
  if s = "" then Ok None
  else
    let is_close = s.[0] = '/' in
    let rest =
      if is_close then String.trim (String.sub s 1 (String.length s - 1)) else s
    in
    let tok = leading_token rest in
    let tail =
      String.trim
        (String.sub rest (String.length tok) (String.length rest - String.length tok))
    in
    if not (tok = "subtree" || tok = "id" || looks_like_level_token tok) then Ok None
    else
      let id =
        if tail = "" then Ok None
        else if tail.[0] = ':' then
          let v = String.trim (String.sub tail 1 (String.length tail - 1)) in
          if v = "" then Error "subtree directive identifier is empty" else Ok (Some v)
        else Error (Printf.sprintf "unexpected text after \"%s\" in subtree directive" tok)
      in
      match id with
      | Error m -> Error m
      | Ok id ->
        if tok = "subtree" || tok = "id" then
          if is_close then Error "use <!-- /hN --> to close a subtree"
          else
            match id with
            | Some v -> Ok (Some (Dir_annotate v))
            | None -> Error (Printf.sprintf "<!-- %s: ID --> requires an identifier" tok)
        else
          match level_of_token tok with
          | None ->
            Error
              (Printf.sprintf
                 "unknown subtree directive \"%s\"; write the level in lowercase, h2 to h6"
                 tok)
          | Some level when level < 2 ->
            Error
              (Printf.sprintf
                 "subtree levels are h2 to h6 (found h%d); h1 is the document root"
                 level)
          | Some level when level > 6 ->
            Error
              (Printf.sprintf
                 "subtree levels are h2 to h6 (found h%d); deeper nesting needs a separate tree"
                 level)
          | Some level ->
            if is_close then
              match id with
              | Some _ -> Error "a closing subtree directive takes no identifier"
              | None -> Ok (Some (Dir_close level))
            else Ok (Some (Dir_open { level; id }))

(* Obsidian marks a block so that it can be linked to by writing `^id` at the
   end of it. That anchor is how the vault addresses the block; Forester
   addresses the subtree by name and has no use for it, so it is dropped rather
   than emitted as text. Only a trailing token counts, and only one that starts
   the run or follows a space, which is what keeps `x^2` intact. *)
let take_block_anchor (inlines : Ir.inline list) : Ir.inline list * string option =
  let is_alnum c =
    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  in
  let is_id_char c = is_alnum c || c = '-' || c = '_' || c = '.' in
  let without_anchor s =
    let len = String.length s in
    let rec back i = if i > 0 && is_id_char s.[i - 1] then back (i - 1) else i in
    let start = back len in
    if start >= len then None (* nothing trailing to take *)
    else if not (is_alnum s.[start]) then None (* an id starts alphanumeric *)
    else if start = 0 || s.[start - 1] <> '^' then None
    else
      let caret = start - 1 in
      if caret > 0 && s.[caret - 1] <> ' ' && s.[caret - 1] <> '\t' then None
      else
        (* The space that separated the anchor went with it. *)
        let rec trim_end i =
          if i > 0 && (s.[i - 1] = ' ' || s.[i - 1] = '\t') then trim_end (i - 1) else i
        in
        Some (String.sub s 0 (trim_end caret), String.sub s start (len - start))
  in
  let anchor = ref None in
  let rec strip_last = function
    | [] -> []
    | [ ({ Ir.node = Ir.Text s; _ } as inline) ] -> (
      match without_anchor s with
      | None -> [ inline ]
      | Some (rest, id) ->
        anchor := Some id;
        if String.trim rest = "" then [] else [ { inline with Ir.node = Ir.Text rest } ])
    | inline :: rest -> inline :: strip_last rest
  in
  (* A break left dangling by a dropped anchor would print as a stray space. *)
  let rec drop_trailing_break = function
    | [] -> []
    | [ { Ir.node = Ir.Soft_break | Ir.Hard_break; _ } ] -> []
    | inline :: rest -> inline :: drop_trailing_break rest
  in
  let stripped = drop_trailing_break (strip_last inlines) in
  (stripped, !anchor)

let strip_block_anchor inlines = fst (take_block_anchor inlines)

(* Lower a single inline list, then check for paragraph normalization.
   Returns either a block_node (Paragraph, Embed, or Display_math)
   plus accumulated diagnostics. *)
let lower_block_inlines source_path base_byte defs inline acc_diags =
  let inlines_rev, diags = lower_inlines source_path base_byte defs inline [] [] in
  let all_diags = acc_diags @ diags in
  let inlines = strip_block_anchor (List.rev inlines_rev) in
  let filtered_unwrapped = filter_wiki_wrappers inlines in
  let filtered = List.filter (fun i ->
    match i.Ir.node with
    | Ir.Text s -> String.trim s <> ""
    | _ -> true
  ) filtered_unwrapped in
  match filtered with
  | [{ Ir.node = Ir.Wiki_embed target; span = _ }] ->
    (Ir.Block_embed target, all_diags)
  | [{ Ir.node = Ir.Math { tex; display = true }; span = _ }] ->
    (Ir.Display_math tex, all_diags)
  | _ ->
    (* Check for mixed content: text + wiki embed or text + display math *)
    let has_embed = List.exists (fun i ->
      match i.Ir.node with Ir.Wiki_embed _ -> true | _ -> false
    ) filtered in
    let has_display_math = List.exists (fun i ->
      match i.Ir.node with Ir.Math { display = true; _ } -> true | _ -> false
    ) filtered in
    let has_text = List.exists (fun i ->
      match i.Ir.node with Ir.Text _ -> true | _ -> false
    ) filtered in
    let extra_diags =
      if has_embed && (has_text || List.length filtered > 1) then
        let span = match filtered with
          | [] -> Span.Source_span { Span.path = source_path; start_byte = 0; end_byte = 0 }
          | i :: _ -> Span.Source_span i.Ir.span
        in
        [Diagnostic.make TM106 span "embeds must appear alone in a paragraph"]
      else if has_display_math && (has_text || List.length filtered > 1) then
        let span = match filtered with
          | [] -> Span.Source_span { Span.path = source_path; start_byte = 0; end_byte = 0 }
          | i :: _ -> Span.Source_span i.Ir.span
        in
        [Diagnostic.make TM107 span "display math must appear alone in a paragraph"]
      else
        []
    in
    (Ir.Paragraph filtered_unwrapped, all_diags @ extra_diags)

(* Recursively lower a Cmarkit block tree into Ir.block list.
   [depth] tracks container nesting: 0 = document, >0 = inside blockquote/list. *)
(* ── Obsidian callouts ──

   `> [!note] Title` is a block quote whose first line names a kind. Nothing in
   CommonMark makes that a construct, so it arrives as ordinary text and is
   recognised here rather than being emitted as a literal `[!note]`, which is
   what a reader would otherwise see on the page. *)

let is_callout_kind_char c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  || c = '-' || c = '_'

(* `[!kind]`, then an optional fold marker, then the rest of the line. *)
let parse_callout_marker text =
  let len = String.length text in
  if len < 4 || text.[0] <> '[' || text.[1] <> '!' then None
  else
    let rec kind_end i =
      if i < len && is_callout_kind_char text.[i] then kind_end (i + 1) else i
    in
    let stop = kind_end 2 in
    if stop = 2 || stop >= len || text.[stop] <> ']' then None
    else
      let kind = String.sub text 2 (stop - 2) in
      let after = stop + 1 in
      let folded, after =
        if after < len && (text.[after] = '+' || text.[after] = '-') then
          (text.[after] = '+', after + 1)
        else (false, after)
      in
      let rec skip_blanks i =
        if i < len && (text.[i] = ' ' || text.[i] = '\t') then skip_blanks (i + 1)
        else i
      in
      let title_start = skip_blanks after in
      Some (kind, folded, String.sub text title_start (len - title_start))

let capitalize_kind kind =
  if kind = "" then kind
  else String.make 1 (Char.uppercase_ascii kind.[0])
       ^ String.lowercase_ascii (String.sub kind 1 (String.length kind - 1))

let rec merge_leading_text acc = function
  | ({ Ir.node = Ir.Text s; _ } : Ir.inline) :: rest -> merge_leading_text (acc ^ s) rest
  | rest -> (acc, rest)

let rec split_at_break before = function
  | ({ Ir.node = (Ir.Soft_break | Ir.Hard_break); _ } : Ir.inline) :: rest ->
    (List.rev before, rest)
  | item :: rest -> split_at_break (item :: before) rest
  | [] -> (List.rev before, [])

let callout_of_blockquote (blocks : Ir.block list) =
  match blocks with
  | ({ Ir.bnode = Ir.Paragraph inlines; bspan = pspan } :: rest_blocks) -> (
    let head, tail = merge_leading_text "" inlines in
    match parse_callout_marker head with
    | None -> None
    | Some (kind, folded, title_head) ->
      let title_tail, body_head = split_at_break [] tail in
      let title_text =
        if title_head = "" then [] else [ { Ir.node = Ir.Text title_head; span = pspan } ]
      in
      let title =
        match title_text @ title_tail with
        | [] -> [ { Ir.node = Ir.Text (capitalize_kind kind); span = pspan } ]
        | titled -> titled
      in
      let body =
        match body_head with
        | [] -> rest_blocks
        | inlines -> { Ir.bnode = Ir.Paragraph inlines; bspan = pspan } :: rest_blocks
      in
      Some (Ir.Callout { kind; folded; title; body }))
  | _ -> None



(* ── Footnotes ──

   Footnotes are numbered by the order they are first referred to, not the
   order they are defined, and their definitions are gathered into one section
   at the end however they were scattered through the note. A definition
   nothing refers to renders nothing, so it is dropped. *)

let footnote_reference_order blocks =
  let order = ref [] in
  let visit inlines =
    List.iter
      (fun (item : Ir.inline) ->
        match item.Ir.node with
        | Ir.Footnote_ref { label; _ } ->
          if not (List.mem label !order) then order := label :: !order
        | _ -> ())
      inlines;
    inlines
  in
  ignore (map_blocks_inlines visit blocks);
  List.rev !order

let number_footnote_refs numbers blocks =
  let visit inlines =
    List.map
      (fun (item : Ir.inline) ->
        match item.Ir.node with
        | Ir.Footnote_ref { label; _ } -> (
          match List.assoc_opt label numbers with
          | Some number -> { item with Ir.node = Ir.Footnote_ref { label; number } }
          | None -> item)
        | _ -> item)
      inlines
  in
  map_blocks_inlines visit blocks

let rec extract_footnote_definitions blocks =
  List.fold_left
    (fun (kept, defs) (block : Ir.block) ->
      match block.Ir.bnode with
      | Ir.Footnote_def { label; body } ->
        let body, nested = extract_footnote_definitions body in
        (kept, defs @ nested @ [ (label, body) ])
      | Ir.Blockquote inner ->
        let inner, nested = extract_footnote_definitions inner in
        (kept @ [ { block with Ir.bnode = Ir.Blockquote inner } ], defs @ nested)
      | Ir.Callout { kind; folded; title; body } ->
        let body, nested = extract_footnote_definitions body in
        (kept @ [ { block with Ir.bnode = Ir.Callout { kind; folded; title; body } } ],
         defs @ nested)
      | Ir.List { kind; tight; items } ->
        let items, nested =
          List.fold_left
            (fun (items, nested) (item : Ir.list_item) ->
              let item_blocks, more = extract_footnote_definitions item.Ir.item_blocks in
              (items @ [ { item with Ir.item_blocks } ], nested @ more))
            ([], []) items
        in
        (kept @ [ { block with Ir.bnode = Ir.List { kind; tight; items } } ],
         defs @ nested)
      | _ -> (kept @ [ block ], defs))
    ([], []) blocks

let gather_footnotes blocks =
  let order = footnote_reference_order blocks in
  let blocks, definitions = extract_footnote_definitions blocks in
  match order with
  | [] -> blocks
  | _ ->
    let numbers = List.mapi (fun index label -> (label, index + 1)) order in
    let entries =
      List.filter_map
        (fun (label, number) ->
          Option.map (fun body -> (number, body)) (List.assoc_opt label definitions))
        numbers
    in
    let blocks = number_footnote_refs numbers blocks in
    if entries = [] then blocks
    else
      let span =
        match List.rev blocks with
        | last :: _ -> last.Ir.bspan
        | [] -> { Span.path = ""; start_byte = 0; end_byte = 0 }
      in
      blocks @ [ { Ir.bnode = Ir.Footnotes entries; bspan = span } ]

let rec lower_blocks source_path depth defs block acc_blocks acc_diags =
  match block with
  | Cmarkit.Block.Blocks (blocks, _meta) ->
    List.fold_left (fun (blks, diags) b ->
      lower_blocks source_path depth defs b blks diags
    ) (acc_blocks, acc_diags) blocks

  | Cmarkit.Block.Paragraph (p, p_meta) ->
    let span = meta_span source_path 0 p_meta in
    let inline = Cmarkit.Block.Paragraph.inline p in
    let node, diags = lower_block_inlines source_path 0 defs inline acc_diags in
    (* At depth > 0, reject embed/display math *)
    let node', diags' =
      if depth > 0 then
        match node with
        | Ir.Block_embed _ ->
          let d = Diagnostic.make TM106 (Span.Source_span span)
            "embeds are only allowed at document level" in
          (Ir.Paragraph [], d :: diags)
        | Ir.Display_math _ ->
          let d = Diagnostic.make TM107 (Span.Source_span span)
            "display math is only allowed at document level" in
          (Ir.Paragraph [], d :: diags)
        | _ -> (node, diags)
      else (node, diags)
    in
    (* A paragraph holding nothing but a block anchor has been emptied by
       stripping it; there is no `\p{}` to emit. *)
    (match node' with
     | Ir.Paragraph [] -> (acc_blocks, diags')
     | _ -> ({ Ir.bnode = node'; bspan = span } :: acc_blocks, diags'))

  | Cmarkit.Block.Heading (h, h_meta) ->
    let span = meta_span source_path 0 h_meta in
    if depth > 0 then
      let diag = Diagnostic.make TM103 (Span.Source_span span)
        "headings are only allowed at document level" in
      (acc_blocks, diag :: acc_diags)
    else
      let level = Cmarkit.Block.Heading.level h in
      let inline = Cmarkit.Block.Heading.inline h in
      let inlines_rev, diags = lower_inlines source_path 0 defs inline [] [] in
      let all_diags = acc_diags @ diags in
      (* An anchor at the end of a heading names the subtree the heading opens.
         It is the one spelling both sides already understand: Obsidian sees a
         block it can link to, Forester gets an address that survives the
         heading being rewritten. It is equivalent to writing the directive
         above the heading, so it becomes one. *)
      let title, anchor = take_block_anchor (filter_wiki_wrappers (List.rev inlines_rev)) in
      if title = [] then
        (* An empty heading used to compile to \title{}, which is a titled
           subtree whose title happens to be blank, not an untitled one. *)
        let diag = Diagnostic.make TM103 (Span.Source_span span)
          "heading has no text; use <!-- hN --> to open an untitled subtree" in
        (acc_blocks, diag :: all_diags)
      else
        let node = Ir.Heading { level; title } in
        let blocks =
          match anchor with
          | None -> acc_blocks
          | Some id ->
            { Ir.bnode = Ir.Subtree_directive id; bspan = span } :: acc_blocks
        in
        ({ Ir.bnode = node; bspan = span } :: blocks, all_diags)

  | Cmarkit.Block.Block_quote (bq, bq_meta) ->
    let span = meta_span source_path 0 bq_meta in
    let inner = Cmarkit.Block.Block_quote.block bq in
    let inner_blocks, diags = lower_blocks source_path (depth + 1) defs inner [] acc_diags in
    let inner_blocks = List.rev inner_blocks in
    let node =
      match callout_of_blockquote inner_blocks with
      | Some callout -> callout
      | None -> Ir.Blockquote inner_blocks
    in
    ({ Ir.bnode = node; bspan = span } :: acc_blocks, diags)

  | Cmarkit.Block.List (l, l_meta) ->
    let span = meta_span source_path 0 l_meta in
    let type' = Cmarkit.Block.List'.type' l in
    let kind = match type' with
      | `Unordered _ -> Ir.Unordered
      | `Ordered (start, _) -> Ir.Ordered start
    in
    let tight = Cmarkit.Block.List'.tight l in
    let items = Cmarkit.Block.List'.items l in
    let item_blocks_rev, diags =
      List.fold_left (fun (items_acc, diags_acc) (item, item_meta) ->
        let item_span = meta_span source_path 0 item_meta in
        (* A task marker becomes a checkbox. Cmarkit reports the marker rune;
           anything other than a blank is a completed item of some kind, and
           HTML has one checked state for all of them. *)
        let item_task =
          match Cmarkit.Block.List_item.ext_task_marker item with
          | None -> None
          | Some (rune, _) -> (
            match Cmarkit.Block.List_item.task_status_of_task_marker rune with
            | `Unchecked -> Some Ir.Task_unchecked
            | `Checked | `Cancelled | `Other _ -> Some Ir.Task_checked)
        in
        let inner = Cmarkit.Block.List_item.block item in
        let child_blocks, child_diags =
          lower_blocks source_path (depth + 1) defs inner [] diags_acc in
        let item_rec =
          { Ir.item_blocks = List.rev child_blocks; item_task; item_span }
        in
        (item_rec :: items_acc, child_diags)
      ) ([], acc_diags) items
    in
    let items_rev = List.rev item_blocks_rev in
    let diags' = diags in
    (* At depth > 0, reject embed/display math inside list items *)
    let diags'' =
      if depth > 0 then
        let check_item item acc =
          let check_block b acc' =
            match b.Ir.bnode with
            | Ir.Block_embed _ ->
              Diagnostic.make TM106 (Span.Source_span b.Ir.bspan)
                "embeds are only allowed at document level" :: acc'
            | Ir.Display_math _ ->
              Diagnostic.make TM107 (Span.Source_span b.Ir.bspan)
                "display math is only allowed at document level" :: acc'
            | _ -> acc'
          in
          List.fold_left (fun acc' b -> check_block b acc') acc item.Ir.item_blocks
        in
        List.fold_left (fun acc item -> check_item item acc) diags' items_rev
      else diags'
    in
    let node = Ir.List { kind; tight; items = items_rev } in
    ({ Ir.bnode = node; bspan = span } :: acc_blocks, diags'')

  | Cmarkit.Block.Code_block (cb, cb_meta) ->
    let span = meta_span source_path 0 cb_meta in
    let layout = Cmarkit.Block.Code_block.layout cb in
    let info_result =
      match layout with
      | `Fenced _ ->
        (match Cmarkit.Block.Code_block.info_string cb with
         | Some info_node -> code_info_of_fence source_path 0 info_node
         | None -> Ok Ir.No_info)
      | `Indented -> Ok Ir.No_info
    in
    (match info_result with
     | Error diag ->
       (acc_blocks, diag :: acc_diags)
     | Ok info ->
       let lines = Cmarkit.Block.Code_block.code cb in
       let code = code_block_lines lines in
       let node = Ir.Code_block { info; code } in
       ({ Ir.bnode = node; bspan = span } :: acc_blocks, acc_diags))

  | Cmarkit.Block.Thematic_break (_tb, tb_meta) ->
    let span = meta_span source_path 0 tb_meta in
    ({ Ir.bnode = Ir.Thematic_break; bspan = span } :: acc_blocks, acc_diags)

  | Cmarkit.Block.Blank_line _ ->
    (acc_blocks, acc_diags)

  | Cmarkit.Block.Link_reference_definition _ ->
    (acc_blocks, acc_diags)

  | Cmarkit.Block.Html_block (hb, hb_meta) ->
    let span = meta_span source_path 0 hb_meta in
    let hb_text = code_block_lines hb in
    let trimmed = String.trim hb_text in
    if is_comment trimmed then
      let reject msg =
        (acc_blocks, Diagnostic.make TM104 (Span.Source_span span) msg :: acc_diags)
      in
      let keep node = ({ Ir.bnode = node; bspan = span } :: acc_blocks, acc_diags) in
      let check_id id k =
        if Metadata.valid_id id then k ()
        else reject ("invalid subtree directive ID: \"" ^ id ^ "\"")
      in
      (match parse_directive (comment_inner trimmed) with
       | Ok None -> (acc_blocks, acc_diags)
       | Error msg -> reject msg
       (* Outline.build only walks the document's own block list, so a
          directive buried in a list item or block quote would vanish
          without a trace. *)
       | Ok (Some _) when depth > 0 ->
         reject "subtree directives are only allowed at document level"
       | Ok (Some (Dir_annotate id)) ->
         check_id id (fun () -> keep (Ir.Subtree_directive id))
       | Ok (Some (Dir_open { level; id = Some id })) ->
         check_id id (fun () -> keep (Ir.Subtree_open { level; id = Some id }))
       | Ok (Some (Dir_open { level; id = None })) ->
         keep (Ir.Subtree_open { level; id = None })
       | Ok (Some (Dir_close level)) -> keep (Ir.Subtree_close level))
    else
      let diag = Diagnostic.make TM102 (Span.Source_span span)
        "raw block HTML is not supported" in
      (acc_blocks, diag :: acc_diags)

  | Cmarkit.Block.Ext_math_block (cb, cb_meta) ->
    let span = meta_span source_path 0 cb_meta in
    let diag = Diagnostic.make TM102 (Span.Source_span span)
      "fenced math blocks are not supported; use $$...$$ for display math" in
    (acc_blocks, diag :: acc_diags)

  | Cmarkit.Block.Ext_table (t, t_meta) ->
    let span = meta_span source_path 0 t_meta in
    let columns = Cmarkit.Block.Table.col_count t in
    let alignment =
      (* The separator row carries the alignment; a table without one has
         none, and every column defaults to none. *)
      let from_sep =
        List.find_map
          (fun ((row, _meta), _blanks) ->
            match row with
            | `Sep seps ->
              Some
                (List.map
                   (fun ((align, _count), _meta) ->
                     match align with
                     | Some `Left -> Ir.Align_left
                     | Some `Center -> Ir.Align_center
                     | Some `Right -> Ir.Align_right
                     | None -> Ir.Align_none)
                   seps)
            | `Header _ | `Data _ -> None)
          (Cmarkit.Block.Table.rows t)
      in
      let found = Option.value ~default:[] from_sep in
      List.init columns (fun i ->
        Option.value ~default:Ir.Align_none (List.nth_opt found i))
    in
    (* Rows are padded to the column count here so that emission never has to
       reason about ragged input. *)
    let lower_cells cells diags =
      let lowered, diags =
        List.fold_left
          (fun (acc, diags) (inline, _layout) ->
            let children, more =
              lower_inlines source_path 0 defs inline [] [] in
            (List.rev children :: acc, diags @ more))
          ([], diags) cells
      in
      let lowered = List.rev lowered in
      let padding = List.init (max 0 (columns - List.length lowered)) (fun _ -> []) in
      (lowered @ padding, diags)
    in
    let header, data, diags =
      List.fold_left
        (fun (header, data, diags) ((row, _meta), _blanks) ->
          match row with
          | `Sep _ -> (header, data, diags)
          | `Header cells ->
            let cells, diags = lower_cells cells diags in
            ((match header with Some _ -> header | None -> Some cells), data, diags)
          | `Data cells ->
            let cells, diags = lower_cells cells diags in
            (header, cells :: data, diags))
        (None, [], acc_diags) (Cmarkit.Block.Table.rows t)
    in
    let node = Ir.Table { alignment; header; rows = List.rev data } in
    (({ Ir.bnode = node; bspan = span } : Ir.block) :: acc_blocks, diags)

  | Cmarkit.Block.Ext_footnote_definition (fn, fn_meta) ->
    let span = meta_span source_path 0 fn_meta in
    let footnote = fn in
    let label = Cmarkit.Label.key (Cmarkit.Block.Footnote.label footnote) in
    let inner = Cmarkit.Block.Footnote.block footnote in
    let body, diags =
      lower_blocks source_path (depth + 1) defs inner [] acc_diags
    in
    let node = Ir.Footnote_def { label; body = List.rev body } in
    (({ Ir.bnode = node; bspan = span } : Ir.block) :: acc_blocks, diags)

  (* Fallback: any unrecognized block extension *)
  | _ ->
    let diag = Diagnostic.make TM102 Span.No_location
      "unsupported Markdown block extension" in
    (acc_blocks, diag :: acc_diags)


(* CommonMark stops at six levels: a run of seven or more "#" is not a heading
   at all but an ordinary paragraph, so a heading nested one level too deep
   turns into body text with its hashes escaped into the output and nothing
   said about it.  The check reads the source rather than the lowered inlines
   so that an intentionally escaped "\#######" is not mistaken for it. *)
let atx_overflow text (b : Ir.block) =
  match b.Ir.bnode with
  | Ir.Paragraph _ ->
    let n = String.length text in
    let start = b.Ir.bspan.Span.start_byte in
    let rec run i = if i < n && text.[i] = '#' then run (i + 1) else i in
    let stop = if start < n then run start else start in
    let hashes = stop - start in
    if hashes >= 7 && (stop >= n || text.[stop] = ' ' || text.[stop] = '\t') then
      Some
        (Diagnostic.make TM103 (Span.Source_span b.Ir.bspan)
           (Printf.sprintf
              "a run of %d \"#\" does not start a heading; Markdown headings stop at h6, \
               so deeper nesting needs a separate tree"
              hashes))
    else None
  | _ -> None

(* parse: lower a complete Markdown document. *)
let parse source ~masked_markdown raw_metadata =
  let doc =
    Cmarkit.Doc.of_string ~locs:true ~strict:false
      ~resolver:(Wiki.resolver source) masked_markdown
  in
  let block = Cmarkit.Doc.block doc in
  let defs = Cmarkit.Doc.defs doc in
  let path = Source.path source in
  let blocks_rev, block_diags = lower_blocks path 0 defs block [] [] in
  let blocks =
    gather_footnotes (map_blocks_inlines obsidian_marks (List.rev blocks_rev))
  in
  let block_diags =
    List.filter_map (atx_overflow masked_markdown) blocks @ block_diags
  in
  let text_len = String.length masked_markdown in
  let doc_span =
    match Span.make ~path ~start_byte:0 ~end_byte:text_len with
    | Ok s -> s
    | Error _ -> { Span.path = path; start_byte = 0; end_byte = text_len }
  in
  (* Lower metadata inline values *)
  let parse_meta located =
    parse_inlines source located.Metadata.value
      ~base_byte:located.Metadata.span.Span.start_byte
  in
  match Metadata.lower_inline_values ~parse:parse_meta raw_metadata with
  | Ok (lowered_meta, meta_warnings) ->
    Diagnostic.gate
      { Ir.metadata = lowered_meta; blocks; doc_span }
      (List.rev block_diags @ meta_warnings)
  | Error meta_diags ->
    Error (List.rev (block_diags @ meta_diags))
