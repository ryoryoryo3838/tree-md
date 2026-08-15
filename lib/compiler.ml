let is_local_image dest =
  let len = String.length dest in
  not ((len >= 7 && String.sub dest 0 7 = "http://")
    || (len >= 8 && String.sub dest 0 8 = "https://"))

let rec collect_inline_refs inlines acc_refs acc_assets =
  List.fold_left (fun (refs, assets) (il : Ir.inline) ->
    match il.Ir.node with
    | Ir.Wiki_link { target; _ } ->
      ({ Ir.kind = Ir.Wiki; target; span = il.Ir.span } :: refs, assets)
    | Ir.Wiki_embed target ->
      ({ Ir.kind = Ir.Embed; target; span = il.Ir.span } :: refs, assets)
    | Ir.Image { destination; _ } ->
      let assets' =
        if is_local_image destination then
          { Parsed_document.destination; span = il.Ir.span } :: assets
        else assets
      in
      (refs, assets')
    | Ir.Emphasis inlines ->
      collect_inline_refs inlines refs assets
    | Ir.Strong inlines ->
      collect_inline_refs inlines refs assets
    | Ir.Link { label; _ } ->
      collect_inline_refs label refs assets
    | _ -> (refs, assets)
  ) (acc_refs, acc_assets) inlines

and collect_block_refs blocks acc_refs acc_assets =
  List.fold_left (fun (refs, assets) (b : Ir.block) ->
    match b.Ir.bnode with
    | Ir.Paragraph inlines ->
      collect_inline_refs inlines refs assets
    | Ir.Blockquote inner ->
      collect_block_refs inner refs assets
    | Ir.List { items; _ } ->
      List.fold_left (fun (r, a) (item : Ir.list_item) ->
        collect_block_refs item.Ir.item_blocks r a
      ) (refs, assets) items
    | Ir.Block_embed target ->
      ({ Ir.kind = Ir.Embed; target; span = b.Ir.bspan } :: refs, assets)
    | Ir.Heading { title; _ } ->
      collect_inline_refs title refs assets
    | _ -> (refs, assets)
  ) (acc_refs, acc_assets) blocks

and collect_section_refs (sections : Outline.section list) acc_refs acc_assets =
  List.fold_left (fun (refs, assets) (sec : Outline.section) ->
    let refs', assets' = collect_block_refs sec.Outline.body refs assets in
    let refs'', assets'' =
      collect_section_refs sec.Outline.children refs' assets'
    in
    (refs'', assets'')
  ) (acc_refs, acc_assets) sections

let collect_meta_refs (meta : Ir.inline list Metadata.t) =
  let from_attributions kind attrs =
    List.filter_map (fun (attr : Metadata.attribution) ->
      match attr with
      | Metadata.Tree { Metadata.value = target; span } ->
        Some { Ir.kind; target; span }
      | Metadata.Literal _ -> None
    ) attrs
  in
  let author_refs = from_attributions Ir.Attribution meta.Metadata.authors in
  let contrib_refs = from_attributions Ir.Attribution meta.Metadata.contributors in
  author_refs @ contrib_refs

let parse ~root_id source =
  match Frontmatter.parse source with
  | Error fm_diags ->
    Error (List.sort Diagnostic.compare fm_diags)
  | Ok fm ->
    let raw_metadata = fm.Frontmatter.metadata in
    match Markdown.parse source ~masked_markdown:fm.Frontmatter.masked_markdown raw_metadata with
    | Error md_diags ->
      Error (List.sort Diagnostic.compare md_diags)
    | Ok doc ->
      let meta = doc.Ir.metadata in
      match Outline.build ~root_id doc with
      | Error ol_diags ->
        Error (List.sort Diagnostic.compare ol_diags)
      | Ok tree ->
        let defs = Outline.definitions tree in
        let body_refs, body_assets = collect_block_refs tree.Outline.body [] [] in
        let section_refs, section_assets =
          collect_section_refs tree.Outline.sections [] [] in
        let meta_refs = collect_meta_refs meta in
        let refs = meta_refs @ body_refs @ section_refs in
        let assets = body_assets @ section_assets in
        Ok {
          Parsed_document.outline = tree;
          definitions = defs;
          references = refs;
          local_assets = assets;
        }

let emit ~resolution (doc : Parsed_document.t) =
  Forester_6.emit ~resolution doc.outline

(* ── Pure forest orchestration ── *)

type expected = {
  source_path : string;
  source_config_relative : Path_safe.relative;
  output_relative : Path_safe.relative;
  bytes : string;
  sha256 : string;
}

let tm404 path message =
  Diagnostic.make TM404 (Span.Path path) message

(* Discovery and compilation are separate passes: a source may have been
   replaced by a symlink or removed in between. Re-check before reading. *)
let read_source (record : Discovery.source_file) =
  match Unix.lstat record.Discovery.path with
  | { Unix.st_kind = Unix.S_REG; _ } ->
    (try
       let channel = open_in_bin record.Discovery.path in
       let contents =
         Fun.protect
           ~finally:(fun () -> close_in_noerr channel)
           (fun () ->
             really_input_string channel (in_channel_length channel))
       in
       Ok contents
     with Sys_error message ->
       Error [ tm404 record.Discovery.path ("cannot read source: " ^ message) ])
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    Error [ tm404 record.Discovery.path "source became a symbolic link" ]
  | { Unix.st_kind = _; _ } ->
    Error [ tm404 record.Discovery.path "source is no longer a regular file" ]
  | exception Unix.Unix_error (error, _, _) ->
    Error
      [ tm404 record.Discovery.path
          ("cannot inspect source: " ^ Unix.error_message error) ]

(* A UTF-8 BOM is itself well-formed UTF-8, so it survives encoding
   validation and is then indistinguishable from ordinary leading text: a
   leading "# Title" stops being an ATX heading, the root title silently
   falls back to the filename stem, and the BOM bytes leak into the emitted
   paragraph. Rejecting it here keeps that corruption from compiling
   successfully. *)
let utf8_bom = "\xef\xbb\xbf"

let starts_with_bom contents =
  String.length contents >= String.length utf8_bom
  && String.sub contents 0 (String.length utf8_bom) = utf8_bom

let parse_source (record : Discovery.source_file) contents =
  if starts_with_bom contents then
    let span =
      { Span.path = record.Discovery.path;
        start_byte = 0;
        end_byte = String.length utf8_bom }
    in
    Error
      [ Diagnostic.make TM003 (Span.Source_span span)
          "file begins with a UTF-8 byte order mark; remove it" ]
  else
  match Source.of_string ~path:record.Discovery.path contents with
  | Error { Source.byte } ->
    let span =
      { Span.path = record.Discovery.path; start_byte = byte; end_byte = byte }
    in
    Error
      [ Diagnostic.make TM001 (Span.Source_span span) "invalid UTF-8" ]
  | Ok source ->
    (match parse ~root_id:record.Discovery.root_id source with
     | Ok document -> Ok (record, document)
     | Error diagnostics -> Error diagnostics)

let sha256_hex bytes =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)

let make_expected (record : Discovery.source_file) bytes =
  { source_path = record.Discovery.path;
    source_config_relative = record.Discovery.config_relative;
    output_relative = record.Discovery.output_relative;
    bytes;
    sha256 = sha256_hex bytes }

let compare_expected (a : expected) (b : expected) =
  let by_output =
    String.compare (Path_safe.to_string a.output_relative)
      (Path_safe.to_string b.output_relative)
  in
  if by_output <> 0 then by_output
  else String.compare a.source_path b.source_path

let emit_documents resolutions records =
  List.fold_left
    (fun (diags, expecteds) ((record : Discovery.source_file), document) ->
      let root_id = document.Parsed_document.outline.Outline.root_id in
      match List.assoc_opt root_id resolutions with
      | None ->
        (Diagnostic.make TM500 Span.No_location
           ("internal error: no resolution for root \"" ^ root_id ^ "\"")
         :: diags, expecteds)
      | Some resolution ->
        (match emit ~resolution document with
         | Error more -> (more @ diags, expecteds)
         | Ok bytes -> (diags, make_expected record bytes :: expecteds)))
    ([], []) records

let compile_forest config discovery =
  let parse_diags, records =
    List.fold_left (fun (diags, records) record ->
      match read_source record with
      | Error more -> (more @ diags, records)
      | Ok contents ->
        (match parse_source record contents with
         | Error more -> (more @ diags, records)
         | Ok parsed -> (diags, parsed :: records))
    ) ([], []) discovery.Discovery.sources
  in
  (* Provisional index from the documents that parsed: valid documents still
     get reference and asset validation, while parse diagnostics from the
     other sources are reported independently. *)
  let documents = List.rev_map snd records in
  let stage_diags, resolutions =
    match
      Forest_index.build ~handwritten:discovery.Discovery.handwritten_roots
        ~generated:documents
    with
    | Error build_diags -> (build_diags, [])
    | Ok index ->
      (match Forest_index.resolve config.Config.forest index ~documents with
       | Error resolve_diags -> (resolve_diags, [])
       | Ok resolutions -> ([], resolutions))
  in
  let emit_diags, expecteds =
    if resolutions = [] then ([], [])
    else emit_documents resolutions records
  in
  let diagnostics =
    List.sort Diagnostic.compare (parse_diags @ stage_diags @ emit_diags)
  in
  if diagnostics <> [] then Error diagnostics
  else Ok (List.sort compare_expected expecteds)
