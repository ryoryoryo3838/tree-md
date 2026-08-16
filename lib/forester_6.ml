let target = "forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be"

(* ── Escaping ── *)

let escape_char buf c =
  match c with
  | '%' -> Buffer.add_char buf '\\'; Buffer.add_char buf '%'
  | '\\' -> Buffer.add_string buf "\\verbFMD|\\FMD"
  | '#' -> Buffer.add_string buf "\\verbFMD|#FMD"
  | '{' -> Buffer.add_string buf "\\verbFMD|{FMD"
  | '}' -> Buffer.add_string buf "\\verbFMD|}FMD"
  | '[' -> Buffer.add_string buf "\\verbFMD|[FMD"
  | ']' -> Buffer.add_string buf "\\verbFMD|]FMD"
  | '(' -> Buffer.add_string buf "\\verbFMD|(FMD"
  | ')' -> Buffer.add_string buf "\\verbFMD|)FMD"
  | _ -> Buffer.add_char buf c

let escape_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (escape_char buf) s;
  Buffer.contents buf

let escape_text_for_test = escape_string

(* ── TeX validation ── *)

let validate_tex tex =
  let len = String.length tex in
  let depth = ref 0 in
  let i = ref 0 in
  while !i < len do
    match tex.[!i] with
    | '\\' when !i + 1 < len ->
      incr i;
      (match tex.[!i] with
       | '{' | '}' -> incr i
       | c when (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ->
         incr i;
         while !i < len && ((tex.[!i] >= 'A' && tex.[!i] <= 'Z')
                         || (tex.[!i] >= 'a' && tex.[!i] <= 'z')) do
           incr i
         done
       | _ -> incr i)
    | '{' -> incr depth; incr i
    | '}' -> decr depth; incr i
    | _ -> incr i
  done;
  !depth = 0

(* ── Writer record ── *)

type writer = {
  errors : Diagnostic.t list ref;
  resolution : Resolution.t;
  text : Buffer.t -> string -> unit;
  safe_id : Buffer.t -> string -> unit;
  uri_text : Buffer.t -> string -> unit;
  xml_attr : Buffer.t -> string -> (Buffer.t -> unit) -> unit;
  meta_key : Buffer.t -> string -> unit;
  tex : Span.t -> Buffer.t -> string -> unit;
}

let make_writer errors resolution =
  let text buf s = String.iter (escape_char buf) s in
  let safe_id buf s = String.iter (fun c -> Buffer.add_char buf c) s in
  let uri_text buf s = String.iter (escape_char buf) s in
  let xml_attr buf name write_value =
    Buffer.add_char buf '[';
    safe_id buf name;
    Buffer.add_char buf ']';
    Buffer.add_char buf '{';
    write_value buf;
    Buffer.add_char buf '}'
  in
  let meta_key buf s = safe_id buf s in
  let tex span buf s =
    if validate_tex s then
      safe_id buf s
    else begin
      let msg = "unbalanced TeX braces" in
      let diag = Diagnostic.make TM107 (Span.Source_span span) msg in
      errors := diag :: !errors;
      safe_id buf s
    end
  in
  { errors; resolution; text; safe_id; uri_text; xml_attr; meta_key; tex }

(* A reference may be written with a spelling that the forest index mapped onto
   a different identity; the emitted tree always names the identity. *)
let resolved_id (w : writer) span target =
  match Resolution.tree_id w.resolution span with
  | Some id -> id
  | None -> target

(* ── URI helpers ── *)

let is_http_uri s =
  let len = String.length s in
  (len >= 7 && String.sub s 0 7 = "http://")
  || (len >= 8 && String.sub s 0 8 = "https://")

let is_external_uri s =
  is_http_uri s
  || (String.length s >= 7 && String.sub s 0 7 = "mailto:")

(* ── Inline emission ── *)

let rec emit_inlines (w : writer) buf (inlines : Ir.inline list) =
  List.iter (fun (il : Ir.inline) ->
    emit_inline_node w buf il.node il.span
  ) inlines

and emit_inline_node (w : writer) buf (node : Ir.inline_node) span =
  match node with
  | Ir.Text s -> w.text buf s
  | Ir.Emphasis inlines ->
    Buffer.add_string buf "\\em{";
    emit_inlines w buf inlines;
    Buffer.add_char buf '}'
  | Ir.Strong inlines ->
    Buffer.add_string buf "\\strong{";
    emit_inlines w buf inlines;
    Buffer.add_char buf '}'
  | Ir.Code s ->
    Buffer.add_string buf "\\code{";
    w.text buf s;
    Buffer.add_char buf '}'
  | Ir.Link { label; destination; title } ->
    emit_link w buf label destination title span
  | Ir.Wiki_link { target; alias } ->
    emit_wiki_link w buf (resolved_id w span target) alias
  | Ir.Wiki_embed target ->
    Buffer.add_string buf "\\transclude{";
    w.safe_id buf (resolved_id w span target);
    Buffer.add_char buf '}'
  | Ir.Math { tex; display = _ } ->
    Buffer.add_string buf "#{";
    w.tex span buf tex;
    Buffer.add_char buf '}'
  | Ir.Image { alt; destination; title } ->
    emit_image w buf alt destination title span
  | Ir.Hard_break ->
    Buffer.add_string buf "\\<html:br>{}"
  | Ir.Soft_break ->
    Buffer.add_char buf ' '

(* Native Forester link forms per the approved profile:
   - [[target]] for wiki links without alias
   - [alias](target) for wiki links with alias
   - [label](dest) for ordinary links without title
   - \<html:a>[href]{URL}[title]{TITLE}{LABEL} for title-bearing external links *)

and emit_wiki_link w buf target alias =
  match alias with
  | Some a ->
    Buffer.add_char buf '[';
    w.text buf a;
    Buffer.add_string buf "](";
    w.safe_id buf target;
    Buffer.add_char buf ')'
  | None ->
    Buffer.add_string buf "[[";
    w.safe_id buf target;
    Buffer.add_string buf "]]"

and emit_link w buf label destination title span =
  let is_ext = is_external_uri destination in
  if is_ext then begin
    match title with
    | Some t ->
      Buffer.add_string buf "\\<html:a>";
      w.xml_attr buf "href" (fun b -> w.uri_text b destination);
      Buffer.add_string buf "[title]{";
      w.text buf t;
      Buffer.add_string buf "}{";
      emit_inlines w buf label;
      Buffer.add_char buf '}'
    | None ->
      Buffer.add_char buf '[';
      emit_inlines w buf label;
      Buffer.add_string buf "](";
      w.uri_text buf destination;
      Buffer.add_char buf ')'
  end else begin
    match title with
    | Some _ ->
      let msg = "local link with HTML title is not supported" in
      let diag = Diagnostic.make TM106 (Span.Source_span span) msg in
      let errs = w.errors in
      errs := diag :: !errs
    | None ->
      Buffer.add_char buf '[';
      emit_inlines w buf label;
      Buffer.add_string buf "](";
      w.uri_text buf destination;
      Buffer.add_char buf ')'
  end

and emit_image w buf alt destination title span =
  let is_ext = is_http_uri destination in
  if is_ext then begin
    Buffer.add_string buf "\\<html:img>";
    w.xml_attr buf "src" (fun b -> w.uri_text b destination);
    let alt_text = flatten_alt w alt in
    Buffer.add_string buf "[alt]{";
    w.text buf alt_text;
    Buffer.add_char buf '}';
    (match title with
     | Some t ->
       Buffer.add_string buf "[title]{";
       w.text buf t;
       Buffer.add_char buf '}'
     | None -> ());
    Buffer.add_string buf "{}"
  end else begin
    match Resolution.asset_route w.resolution span with
    | Some routed ->
      Buffer.add_string buf "\\<html:img>";
      Buffer.add_string buf "[src]{";
      Buffer.add_string buf "\\route-asset{";
      w.text buf routed;
      Buffer.add_string buf "}}";
      let alt_text = flatten_alt w alt in
      Buffer.add_string buf "[alt]{";
      w.text buf alt_text;
      Buffer.add_string buf "}{}"
    | None ->
      let msg = "unresolved local image (no route-asset mapping)" in
      let diag = Diagnostic.make TM106 (Span.Source_span span) msg in
      let errs = w.errors in
      errs := diag :: !errs
  end

and flatten_alt (w : writer) (inlines : Ir.inline list) : string =
  let buf = Buffer.create 64 in
  let rec go = function
    | [] -> ()
    | { Ir.node = Ir.Text s; _ } :: rest ->
      w.text buf s;
      go rest
    | { Ir.node = Ir.Code s; _ } :: rest ->
      w.text buf s;
      go rest
    | { Ir.node = Ir.Emphasis is; _ } :: rest ->
      go (is @ rest)
    | { Ir.node = Ir.Strong is; _ } :: rest ->
      go (is @ rest)
    | { Ir.node = Ir.Link { label; _ }; _ } :: rest ->
      go (label @ rest)
    | { Ir.node = Ir.Wiki_link { target; alias }; _ } :: rest ->
      (match alias with
       | Some a -> w.text buf a
       | None -> w.text buf target);
      go rest
    | { Ir.node = Ir.Math { tex; _ }; _ } :: rest ->
      w.text buf tex;
      go rest
    | { Ir.node = (Ir.Hard_break | Ir.Soft_break); _ } :: rest ->
      Buffer.add_char buf ' ';
      go rest
    | { Ir.node = Ir.Image _; Ir.span = ispan } :: _ ->
      let msg = "nested image in alt text" in
      let diag = Diagnostic.make TM106 (Span.Source_span ispan) msg in
      let errs = w.errors in
      errs := diag :: !errs
    | { Ir.node = Ir.Wiki_embed _; Ir.span = wspan } :: _ ->
      let msg = "wiki embed in alt text" in
      let diag = Diagnostic.make TM106 (Span.Source_span wspan) msg in
      let errs = w.errors in
      errs := diag :: !errs
  in
  go inlines;
  Buffer.contents buf

(* ── Block emission ── *)

let rec emit_block (w : writer) buf (block : Ir.block) =
  match block.Ir.bnode with
  | Ir.Paragraph inlines ->
    Buffer.add_string buf "\\p{";
    emit_inlines w buf inlines;
    Buffer.add_char buf '}'
  | Ir.Blockquote blocks ->
    Buffer.add_string buf "\\blockquote{";
    emit_blocks_body w buf blocks;
    Buffer.add_char buf '}'
  | Ir.List { kind; tight; items } ->
    emit_list w buf kind tight items
  | Ir.Code_block { info; code } ->
    emit_code_block w buf info code
  | Ir.Thematic_break ->
    Buffer.add_string buf "\\<html:hr>{}"
  | Ir.Heading { level = _; title = _ } ->
    ()
  | Ir.Subtree_directive _ | Ir.Subtree_open _ | Ir.Subtree_close _ ->
    ()
  | Ir.Block_embed id ->
    Buffer.add_string buf "\\transclude{";
    w.safe_id buf (resolved_id w block.Ir.bspan id);
    Buffer.add_char buf '}'
  | Ir.Display_math tex ->
    Buffer.add_string buf "##{";
    w.tex block.Ir.bspan buf tex;
    Buffer.add_char buf '}'

and emit_blocks_body (w : writer) buf (blocks : Ir.block list) =
  let rec loop = function
    | [] -> ()
    | [b] -> emit_block w buf b
    | b :: rest ->
      emit_block w buf b;
      Buffer.add_string buf "\n\n";
      loop rest
  in
  loop blocks

and emit_list (w : writer) buf kind tight (items : Ir.list_item list) =
  let is_ordered_start_gt_1 = match kind with
    | Ir.Ordered n when n <> 1 -> true
    | _ -> false
  in
  if is_ordered_start_gt_1 then begin
    let n = match kind with Ir.Ordered n -> n | _ -> 1 in
    Buffer.add_string buf "\\<html:ol>";
    Buffer.add_string buf "[start]{";
    Buffer.add_string buf (string_of_int n);
    Buffer.add_string buf "}{";
    emit_items w buf "" tight items;
    Buffer.add_char buf '}'
  end else begin
    let wrapper = match kind with
      | Ir.Ordered _ -> "\\ol{"
      | Ir.Unordered -> "\\ul{"
    in
    Buffer.add_string buf wrapper;
    emit_items w buf "\n" tight items;
    Buffer.add_char buf '}'
  end

and emit_items (w : writer) buf sep tight (items : Ir.list_item list) =
  let rec loop first remaining =
    match remaining with
    | [] -> ()
    | [item] ->
      if not first then Buffer.add_string buf sep;
      emit_list_item w buf tight item.Ir.item_blocks
    | item :: rest ->
      if not first then Buffer.add_string buf sep;
      emit_list_item w buf tight item.Ir.item_blocks;
      loop false rest
  in
  loop true items

and emit_list_item (w : writer) buf tight (blocks : Ir.block list) =
  Buffer.add_string buf "\\li{";
  (match blocks with
   | [Ir.{ bnode = Ir.Paragraph inlines; _ }] when tight ->
     emit_inlines w buf inlines
   | _ ->
     emit_blocks_inside_li w buf tight blocks);
  Buffer.add_char buf '}'

and emit_blocks_inside_li (w : writer) buf tight (blocks : Ir.block list) =
  let rec loop = function
    | [] -> ()
    | [Ir.{ bnode = Ir.Paragraph inlines; _ }] when not tight ->
      Buffer.add_string buf "\\p{";
      emit_inlines w buf inlines;
      Buffer.add_char buf '}'
    | [b] -> emit_block w buf b
    | Ir.{ bnode = Ir.Paragraph inlines; _ } :: rest when not tight ->
      Buffer.add_string buf "\\p{";
      emit_inlines w buf inlines;
      Buffer.add_char buf '}';
      Buffer.add_string buf "\n";
      loop rest
    | b :: rest ->
      emit_block w buf b;
      Buffer.add_string buf "\n";
      loop rest
  in
  loop blocks

and emit_code_block (w : writer) buf info code =
  Buffer.add_string buf "\\<html:pre>";
  (match info with
   | Ir.Language lang ->
     Buffer.add_string buf "[class]{language-";
     w.text buf lang;
     Buffer.add_char buf '}'
   | Ir.No_info -> ());
  Buffer.add_string buf "{\\<html:code>{";
  w.text buf code;
  Buffer.add_string buf "}}"

(* ── Metadata emission ── *)

let emit_attribution_inline w buf (attr : Metadata.attribution) =
  match attr with
  | Metadata.Literal { Metadata.value = name; _ } ->
    w.text buf name
  | Metadata.Tree { Metadata.value = id; _ } ->
    w.safe_id buf id

let emit_title_inlines w buf (inlines : Ir.inline list) =
  Buffer.add_string buf "\\title{";
  emit_inlines w buf inlines;
  Buffer.add_char buf '}';
  Buffer.add_char buf '\n'

let emit_metadata (w : writer) buf (meta : Ir.inline list Metadata.t) =
  (match meta.Metadata.date with
   | Some { Metadata.value = d; _ } ->
     Buffer.add_string buf "\\date{";
     w.text buf d;
     Buffer.add_string buf "}\n"
   | None -> ());
  (match meta.Metadata.taxon with
   | Some { Metadata.value = t; _ } ->
     Buffer.add_string buf "\\taxon{";
     w.text buf t;
     Buffer.add_string buf "}\n"
   | None -> ());
  List.iter (fun attr ->
    let prefix = match attr with
      | Metadata.Tree _ -> "\\author{"
      | Metadata.Literal _ -> "\\author/literal{"
    in
    Buffer.add_string buf prefix;
    emit_attribution_inline w buf attr;
    Buffer.add_string buf "}\n"
  ) meta.Metadata.authors;
  List.iter (fun attr ->
    let prefix = match attr with
      | Metadata.Tree _ -> "\\contributor{"
      | Metadata.Literal _ -> "\\contributor/literal{"
    in
    Buffer.add_string buf prefix;
    emit_attribution_inline w buf attr;
    Buffer.add_string buf "}\n"
  ) meta.Metadata.contributors;
  List.iter (fun { Metadata.value = inlines; _ } ->
    Buffer.add_string buf "\\tag{";
    emit_inlines w buf inlines;
    Buffer.add_string buf "}\n"
  ) meta.Metadata.tags;
  List.iter (fun ({ Metadata.value = key; _ },
                  { Metadata.value = inlines; _ }) ->
    Buffer.add_string buf "\\meta{";
    w.meta_key buf key;
    Buffer.add_string buf "}{";
    emit_inlines w buf inlines;
    Buffer.add_string buf "}\n"
  ) meta.Metadata.meta

(* ── Section emission (\\subtree form) ── *)

let emit_title_command w buf (inlines : Ir.inline list) =
  Buffer.add_string buf "\\title{";
  emit_inlines w buf inlines;
  Buffer.add_char buf '}'

(* Every item is followed by a newline; a blank line is inserted before an item
   when it is separated from the one before it.  At the top level everything is
   separated, inside a subtree only consecutive blocks are run together. *)
let rec emit_content ~top (w : writer) buf (items : Outline.content list) =
  let separated prev item =
    top ||
    match prev, item with
    | Outline.Block _, Outline.Block _ -> false
    | _ -> true
  in
  let rec loop prev = function
    | [] -> ()
    | item :: rest ->
      (match prev with
       | Some p when separated p item -> Buffer.add_char buf '\n'
       | _ -> ());
      (match item with
       | Outline.Block b -> emit_block w buf b
       | Outline.Section s -> emit_subtree w buf s);
      Buffer.add_char buf '\n';
      loop (Some item) rest
  in
  loop None items

and emit_subtree (w : writer) buf (sec : Outline.section) =
  Buffer.add_string buf "\\subtree";
  (match sec.Outline.id with
   | Some id ->
     Buffer.add_char buf '[';
     w.safe_id buf id;
     Buffer.add_char buf ']'
   | None -> ());
  Buffer.add_string buf "{";
  let has_content = sec.Outline.content <> [] in
  if has_content then Buffer.add_char buf '\n';
  (match sec.Outline.title with
   | Some title ->
     emit_title_command w buf title;
     if has_content then Buffer.add_char buf '\n'
   | None -> ());
  if has_content then emit_content ~top:false w buf sec.Outline.content;
  Buffer.add_char buf '}'

(* ── Top-level block emission ── *)

let emit_blocks_top (w : writer) buf (blocks : Ir.block list) =
  let rec loop first remaining =
    match remaining with
    | [] -> ()
    | b :: rest ->
      if not first then Buffer.add_char buf '\n';
      emit_block w buf b;
      Buffer.add_char buf '\n';
      loop false rest
  in
  loop true blocks

(* ── Main emit ── *)

let emit ~(resolution : Resolution.t) (tree : Outline.t) =
  let errors = ref [] in
  let w = make_writer errors resolution in
  let buf = Buffer.create 4096 in

  emit_title_inlines w buf tree.Outline.title;

  let has_meta =
    tree.Outline.metadata.Metadata.date <> None
    || tree.Outline.metadata.Metadata.taxon <> None
    || tree.Outline.metadata.Metadata.authors <> []
    || tree.Outline.metadata.Metadata.contributors <> []
    || tree.Outline.metadata.Metadata.tags <> []
    || tree.Outline.metadata.Metadata.meta <> []
  in
  emit_metadata w buf tree.Outline.metadata;

  if tree.Outline.content <> [] then begin
    if has_meta then Buffer.add_char buf '\n';
    emit_content ~top:true w buf tree.Outline.content
  end;

  let out = Buffer.contents buf in
  let errs = List.rev !errors in
  if errs = [] then Ok out
  else Error errs
