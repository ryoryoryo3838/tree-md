let is_local_image dest =
  let len = String.length dest in
  not ((len >= 7 && String.sub dest 0 7 = "http://")
    || (len >= 8 && String.sub dest 0 8 = "https://"))

let is_external_uri s =
  let len = String.length s in
  (len >= 7 && String.sub s 0 7 = "http://")
  || (len >= 8 && String.sub s 0 8 = "https://")
  || (len >= 7 && String.sub s 0 7 = "mailto:")

(* In Forester, `[label](addr)` is a tree reference, not a URL: there is no
   relative-link form. So a Markdown link whose destination is not an external
   URI names a tree, and mdbase v0.3 §08 says as much — a Markdown link is a
   link. Resolving it is what keeps `[see](note.md)` from emitting a reference
   to an address no tree has. A bare fragment is left alone. *)
let is_tree_reference destination =
  destination <> ""
  && destination.[0] <> '#'
  && not (is_external_uri destination)

let rec collect_inline_refs inlines acc_refs acc_assets =
  List.fold_left (fun (refs, assets) (il : Ir.inline) ->
    match il.Ir.node with
    | Ir.Wiki_link { target; _ } ->
      ({ Ir.kind = Ir.Wiki; target; span = il.Ir.span } :: refs, assets)
    | Ir.Wiki_embed target ->
      ({ Ir.kind = Ir.Embed; target; span = il.Ir.span } :: refs, assets)
    | Ir.Image { asset_path = destination; _ } ->
      let assets' =
        if is_local_image destination then
          { Parsed_document.destination; span = il.Ir.span } :: assets
        else assets
      in
      (refs, assets')
    | Ir.Emphasis inlines | Ir.Strong inlines
    | Ir.Strikethrough inlines | Ir.Highlight inlines ->
      collect_inline_refs inlines refs assets
    | Ir.Link { label; destination; _ } ->
      let refs =
        if is_tree_reference destination then
          { Ir.kind = Ir.Markdown_link; target = destination; span = il.Ir.span }
          :: refs
        else refs
      in
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
    | Ir.Callout { title; body; _ } ->
      let refs, assets = collect_inline_refs title refs assets in
      collect_block_refs body refs assets
    | Ir.Table { header; rows; _ } ->
      let cells = Option.to_list header @ rows in
      List.fold_left
        (fun (r, a) row ->
          List.fold_left (fun (r, a) cell -> collect_inline_refs cell r a) (r, a) row)
        (refs, assets) cells
    | Ir.Footnote_def { body; _ } -> collect_block_refs body refs assets
    | Ir.Footnotes entries ->
      List.fold_left
        (fun (r, a) (_number, body) -> collect_block_refs body r a)
        (refs, assets) entries
    | _ -> (refs, assets)
  ) (acc_refs, acc_assets) blocks

and collect_content_refs (items : Outline.content list) acc_refs acc_assets =
  List.fold_left (fun (refs, assets) item ->
    match item with
    | Outline.Block b -> collect_block_refs [b] refs assets
    | Outline.Section sec -> collect_content_refs sec.Outline.content refs assets
  ) (acc_refs, acc_assets) items

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

(* A tree with no address of its own is *pending*: `build` mints one for it.
   Until then it needs some identity to compile under, and that identity must
   be one no reference can name and no two trees can share. The path gives
   uniqueness and the NUL prefix keeps it out of Metadata.valid_id, so a
   [[link]] can never reach it and it can never be emitted as an address. *)
let pending_prefix = "\x00pending:"

let pending_identity (record : Discovery.source_file) =
  pending_prefix ^ Path_safe.to_string record.Discovery.source_relative

let is_pending id =
  String.length id >= String.length pending_prefix
  && String.sub id 0 (String.length pending_prefix) = pending_prefix

(* [default_id] is the identity to compile under when the front matter states
   none. [filename] is the stem, which is what an absent H1 falls back to for
   the title — the file is what the writer named, and the address may since
   have become a number that says nothing. *)
(* ── the mdbase collection layer ──

   What the collection declares about its records: how strict validation is,
   which key names declare a type, which field is the address, and the types
   themselves. A forest with no `mdbase.yaml` and no `_types/` gets the
   defaults and nothing changes. *)
type mdbase = {
  settings : Mdbase_config.t;
  types : Mdbase_type.t list;
}

let no_mdbase = { settings = Mdbase_config.default; types = [] }

let load_mdbase (config : Config.t) =
  match Mdbase_config.load ~directory:config.Config.directory with
  | Error diagnostics -> Error diagnostics
  | Ok (settings, config_warnings) -> (
    match Mdbase_type.load ~directory:config.Config.directory ~config:settings with
    | Error diagnostics -> Error diagnostics
    | Ok (types, type_warnings) ->
      Ok ({ settings; types }, config_warnings @ type_warnings))

(* A schema issue is reported at the severity `settings.validation` asks for,
   and carries mdbase's canonical code beside tree-md's own. *)
let schema_diagnostics ~mdbase ~frontmatter ~type_name (issues : Json_schema.issue list) =
  match mdbase.settings.Mdbase_config.validation with
  | Mdbase_config.Off -> []
  | level ->
    List.map
      (fun (issue : Json_schema.issue) ->
        let location =
          match Option.bind frontmatter (fun node ->
                  Yaml_json.locate node issue.Json_schema.pointer)
          with
          | Some span -> Span.Source_span span
          | None -> Span.No_location
        in
        let message =
          (if issue.Json_schema.pointer = "" then "" else issue.Json_schema.pointer ^ ": ")
          ^ issue.Json_schema.message
          ^ " (type \"" ^ type_name ^ "\")"
        in
        let make =
          match level with
          | Mdbase_config.Warn -> Diagnostic.warn
          | Mdbase_config.Strict | Mdbase_config.Off -> Diagnostic.make
        in
        make ~mdbase_code:issue.Json_schema.code TM101 location message)
      issues

let parse ?(mdbase = no_mdbase) ?(collection_path = "") ~default_id ~filename source =
  let sorted diags = List.sort Diagnostic.compare diags in
  match Frontmatter.parse source with
  | Error fm_diags ->
    Error (sorted fm_diags)
  | Ok (fm, fm_warnings) ->
    (* mdbase v0.3 §05: the JSON Schema validates the *raw persisted* front
       matter, and read defaults enter afterwards. *)
    let persisted =
      match fm.Frontmatter.frontmatter with
      | Some node -> Yaml_json.to_yojson node
      | None -> `Assoc []
    in
    let types, select_warnings =
      Mdbase_type.select mdbase.types ~config:mdbase.settings ~collection_path
        ~frontmatter:persisted
    in
    let schema_diags =
      List.concat_map
        (fun declared ->
          schema_diagnostics ~mdbase ~frontmatter:fm.Frontmatter.frontmatter
            ~type_name:(Mdbase_type.name declared)
            (Mdbase_type.validate declared persisted))
        types
    in
    let mdbase_diags = select_warnings @ schema_diags in
    if Diagnostic.has_error mdbase_diags then
      Error (sorted (fm_warnings @ mdbase_diags))
    else
    (* Effective front matter is what tree-md then reads: the persisted mapping
       plus a value for each key a matched type defaults. Nothing is written to
       the note. *)
    let effective =
      match fm.Frontmatter.frontmatter with
      | None -> None
      | Some node ->
        Some
          (List.fold_left
             (fun node declared ->
               Yaml_json.with_defaults node (Mdbase_type.read_defaults declared))
             node types)
    in
    let raw_metadata, lowering_diags =
      Metadata.of_yaml ~id_field:mdbase.settings.Mdbase_config.id_field effective
    in
    let fm_warnings = fm_warnings @ mdbase_diags @ lowering_diags in
    if Diagnostic.has_error fm_warnings then Error (sorted fm_warnings) else
    match Markdown.parse source ~masked_markdown:fm.Frontmatter.masked_markdown raw_metadata with
    | Error md_diags ->
      Error (sorted (fm_warnings @ md_diags))
    | Ok (doc, md_warnings) ->
      let meta = doc.Ir.metadata in
      (* A stated `id` is the tree's identity; the file name is only the
         fallback. That is what lets a note be renamed without moving the
         address the site and every reference already use. *)
      let root_id =
        match raw_metadata.Metadata.id with
        | Some stated -> stated.Metadata.value
        | None -> default_id
      in
      match Outline.build ~root_id ~filename doc with
      | Error ol_diags ->
        Error (sorted (fm_warnings @ md_warnings @ ol_diags))
      | Ok (tree, ol_warnings) ->
        let defs = Outline.definitions tree in
        let content_refs, assets = collect_content_refs tree.Outline.content [] [] in
        let meta_refs = collect_meta_refs meta in
        let refs = meta_refs @ content_refs in
        Ok ({
          Parsed_document.outline = tree;
          definitions = defs;
          references = refs;
          local_assets = assets;
        }, sorted (fm_warnings @ md_warnings @ ol_warnings))

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

let parse_source ~mdbase ~default_id (record : Discovery.source_file) contents =
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
    (match
       parse ~mdbase
         ~collection_path:(Path_safe.to_string record.Discovery.config_relative)
         ~default_id ~filename:record.Discovery.filename source
     with
     | Ok (document, warnings) -> Ok ((record, document), warnings)
     | Error diagnostics -> Error diagnostics)

let sha256_hex bytes =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)

(* The output is named by the tree's identity rather than by the file it came
   from, so `id: mlnet-7` in `a/note.tree.md` lands in `a/mlnet-7.tree`. The
   directory is still mirrored: Forester reads identity from the file name
   alone and treats the directory as organisation. *)
let output_for (record : Discovery.source_file) root_id =
  let source = Path_safe.to_string record.Discovery.source_relative in
  let dir =
    match String.rindex_opt source '/' with
    | None -> ""
    | Some i -> String.sub source 0 (i + 1)
  in
  match Path_safe.relative (dir ^ root_id ^ ".tree") with
  | Ok relative -> relative
  | Error _ -> record.Discovery.output_relative

let make_expected (record : Discovery.source_file) root_id bytes =
  { source_path = record.Discovery.path;
    source_config_relative = record.Discovery.config_relative;
    output_relative = output_for record root_id;
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
         | Ok (bytes, warnings) ->
           (warnings @ diags, make_expected record root_id bytes :: expecteds)))
    ([], []) records

(* A file name can stand in for an address only when it could be one at all
   and exactly one tree answers to it. 日本語のノート and "My Note" cannot be
   Forester addresses, and two folders may each hold a note.tree.md; in either
   case the tree is left unaddressed for `build` to mint. *)
let stem_fallback (sources : Discovery.source_file list) =
  let counts = Hashtbl.create 64 in
  List.iter
    (fun (record : Discovery.source_file) ->
      let stem = record.Discovery.filename in
      let seen = Option.value ~default:0 (Hashtbl.find_opt counts stem) in
      Hashtbl.replace counts stem (seen + 1))
    sources;
  fun (record : Discovery.source_file) ->
    let stem = record.Discovery.filename in
    if Metadata.valid_id stem && Hashtbl.find_opt counts stem = Some 1 then stem
    else pending_identity record

(* File names are in here as well as identities. A tree that states no id
   answers to its file name today, and an address that collided with one would
   silently take a reference away from it. *)
let identities ?(mdbase = no_mdbase) _config (discovery : Discovery.t) =
  let default_id = stem_fallback discovery.Discovery.sources in
  let from_sources =
    List.fold_left
      (fun acc (record : Discovery.source_file) ->
        let stem = record.Discovery.filename in
        match read_source record with
        | Error _ -> stem :: acc
        | Ok contents -> (
          match
            parse_source ~mdbase ~default_id:(default_id record) record contents
          with
          | Error _ -> stem :: acc
          | Ok ((_, document), _) ->
            let root = document.Parsed_document.outline.Outline.root_id in
            let subtrees =
              List.map
                (fun (d : Outline.definition) -> d.Outline.id)
                document.Parsed_document.definitions
            in
            (stem :: root :: subtrees) @ acc))
      [] discovery.Discovery.sources
  in
  let handwritten =
    List.map
      (fun (r : Discovery.handwritten_root) -> r.Discovery.id)
      discovery.Discovery.handwritten_roots
  in
  Ok (List.sort_uniq String.compare (from_sources @ handwritten))

(* An address is a published URL. A tree that has none cannot name an output,
   so saying which file it is and what to do about it beats failing on the
   file name it happens to have. *)
let tm206 (record : Discovery.source_file) =
  Diagnostic.make TM206 (Span.Path record.Discovery.path)
    ("tree has no address, and its file name \"" ^ record.Discovery.filename
     ^ "\" cannot be one; state `id:` in its front matter, or let `build` \
        mint one for it")

(* [allow_pending] is set only for the compile that precedes minting. That
   compile exists to prove the forest is sound before anything is rewritten,
   and a tree waiting for an address is exactly what it is about to fix. *)
let compile_forest ?(allow_pending = false) ?mdbase config discovery =
  let loaded =
    match mdbase with
    | Some loaded -> Ok (loaded, [])
    | None -> load_mdbase config
  in
  match loaded with
  | Error diagnostics -> Error diagnostics
  | Ok (mdbase, mdbase_warnings) ->
  let default_id = stem_fallback discovery.Discovery.sources in
  let parse_diags, records =
    List.fold_left (fun (diags, records) record ->
      match read_source record with
      | Error more -> (more @ diags, records)
      | Ok contents ->
        (match
           parse_source ~mdbase ~default_id:(default_id record) record contents
         with
         | Error more -> (more @ diags, records)
         | Ok (parsed, warnings) -> (warnings @ diags, parsed :: records))
    ) ([], []) discovery.Discovery.sources
  in
  let pending_diags =
    if allow_pending then []
    else
      List.filter_map
        (fun ((record : Discovery.source_file), (document : Parsed_document.t)) ->
          if is_pending document.Parsed_document.outline.Outline.root_id then
            Some (tm206 record)
          else None)
        records
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
       | Ok (resolutions, warnings) -> (warnings, resolutions))
  in
  let emit_diags, expecteds =
    if resolutions = [] then ([], [])
    else emit_documents resolutions records
  in
  let diagnostics =
    List.sort Diagnostic.compare
      (mdbase_warnings @ parse_diags @ pending_diags @ stage_diags @ emit_diags)
  in
  Diagnostic.gate (List.sort compare_expected expecteds) diagnostics
