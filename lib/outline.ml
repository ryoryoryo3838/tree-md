(* A tree's body is one ordered sequence, not a block list followed by a
   section list: a closing directive can end a subtree and return to the
   parent's body, so blocks and subtrees interleave. *)
type content =
  | Block of Ir.block
  | Section of section

(* [title] is [None] when the subtree was opened by an <!-- hN --> directive
   rather than a heading.  Forester allows a subtree with no \title, which no
   Markdown heading can express. *)
and section = {
  id : string option;
  definition_span : Span.t option;
  title : Ir.inline list option;
  content : content list;
  span : Span.t;
}

type t = {
  root_id : string;
  title : Ir.inline list;
  metadata : Ir.inline list Metadata.t;
  content : content list;
  span : Span.t;
}

type definition = { id : string; span : Span.t }

let blocks content =
  List.filter_map (function Block b -> Some b | Section _ -> None) content

let subtrees content =
  List.filter_map (function Section s -> Some s | Block _ -> None) content

type stack_entry = {
  se_level : int;
  se_id : string option;
  se_def_span : Span.t option;
  se_title : Ir.inline list option;
  se_open_span : Span.t;
  se_content_rev : content list ref;
}

let zero_span path =
  match Span.make ~path ~start_byte:0 ~end_byte:0 with
  | Ok s -> s | Error _ -> failwith "cannot create zero span"

let fallback_title path filename =
  { Ir.node = Ir.Text filename; Ir.span = zero_span path }

let content_span = function
  | Block b -> b.Ir.bspan
  | Section s -> s.span

let section_span se (content : content list) =
  let end_byte =
    List.fold_left
      (fun acc c -> max acc (content_span c).Span.end_byte)
      se.se_open_span.Span.end_byte content
  in
  match Span.make ~path:se.se_open_span.Span.path
          ~start_byte:se.se_open_span.Span.start_byte ~end_byte with
  | Ok s -> s | Error _ -> se.se_open_span

let finalize_stack_entry (se : stack_entry) =
  let content = List.rev !(se.se_content_rev) in
  { id = se.se_id; definition_span = se.se_def_span;
    title = se.se_title; content; span = section_span se content }

let push_stack_entry stack level id_opt def_span_opt title open_span =
  stack := { se_level = level; se_id = id_opt; se_def_span = def_span_opt;
             se_title = title; se_open_span = open_span;
             se_content_rev = ref [] } :: !stack

let pop_while stack keep =
  let rec loop () =
    match !stack with
    | se :: rest when keep se ->
      let finalized = finalize_stack_entry se in
      stack := rest;
      (match !stack with
       | parent :: _ ->
         parent.se_content_rev := Section finalized :: !(parent.se_content_rev)
       | [] -> ());
      loop ()
    | _ -> ()
  in
  loop ()

let pop_sections_above stack n = pop_while stack (fun se -> se.se_level > n)
let pop_sections_ge stack n = pop_while stack (fun se -> se.se_level >= n)

let build ~root_id ~filename (doc : Ir.document) =
  let diags = ref [] in
  let root_title = ref None in
  let non_h1_content_seen = ref false in
  let pending_directive : (string * Span.t) option ref = ref None in

  let emit code loc msg =
    diags := Diagnostic.make code loc msg :: !diags
  in

  let doc_path = doc.Ir.doc_span.Span.path in

  (* Stack starts with root container at level 1 *)
  let stack : stack_entry list ref = ref [] in
  push_stack_entry stack 1 None None None doc.Ir.doc_span;

  (* A pending <!-- subtree: ID --> names the heading that follows it, so
     anything else appearing first loses it. *)
  let drop_pending_directive span what =
    match !pending_directive with
    | Some _ ->
      emit TM104 (Span.Source_span span) what;
      pending_directive := None
    | None -> ()
  in

  let parent_level () = match !stack with se :: _ -> se.se_level | [] -> 1 in

  let check_level_step level span =
    let parent = parent_level () in
    if parent < level - 1 then
      emit TM103 (Span.Source_span span)
        (Printf.sprintf "heading level %d follows level %d (level skipped; expected level %d)"
           level parent (parent + 1))
  in

  List.iter (fun (block : Ir.block) ->
    match block.Ir.bnode with
    | Ir.Heading { level = 1; title } ->
      if !root_title <> None then
        emit TM103 (Span.Source_span block.Ir.bspan) "duplicate H1 heading"
      else if !non_h1_content_seen then
        emit TM103 (Span.Source_span block.Ir.bspan) "H1 heading must be the first block in the document"
      else begin
        drop_pending_directive block.Ir.bspan "subtree directive before H1 heading";
        root_title := Some title
      end

    | Ir.Heading { level; title } ->
      non_h1_content_seen := true;
      pop_sections_ge stack level;
      check_level_step level block.Ir.bspan;
      let id_opt, def_span_opt = match !pending_directive with
        | Some (dir_id, dir_span) ->
          pending_directive := None;
          (Some dir_id, Some dir_span)
        | None -> (None, None)
      in
      push_stack_entry stack level id_opt def_span_opt (Some title) block.Ir.bspan

    | Ir.Subtree_open { level; id } ->
      non_h1_content_seen := true;
      drop_pending_directive block.Ir.bspan
        "subtree directive followed by another subtree directive instead of a heading";
      pop_sections_ge stack level;
      check_level_step level block.Ir.bspan;
      let def_span = match id with Some _ -> Some block.Ir.bspan | None -> None in
      push_stack_entry stack level id def_span None block.Ir.bspan

    | Ir.Subtree_close level ->
      drop_pending_directive block.Ir.bspan
        "subtree directive followed by a closing directive instead of a heading";
      if List.exists (fun se -> se.se_level >= level) !stack then
        pop_sections_ge stack level
      else
        emit TM104 (Span.Source_span block.Ir.bspan)
          (Printf.sprintf "no open subtree at level h%d to close" level)

    | Ir.Subtree_directive id ->
      (* Directives do not count as content for H1-first rule *)
      (match !pending_directive with
       | Some (prev_id, _) ->
         emit TM104 (Span.Source_span block.Ir.bspan)
           (Printf.sprintf "multiple subtree directives without a heading (previous directive \"%s\" lost)" prev_id)
       | None -> ());
      pending_directive := Some (id, block.Ir.bspan)

    (* The footnote section belongs to the note, not to whichever section
       happened to be open when the document ran out, so every open subtree is
       closed before it is placed. There may be none open, which is ordinary
       rather than the error a written `<!-- /hN -->` would be. *)
    | Ir.Footnotes _ ->
      non_h1_content_seen := true;
      drop_pending_directive block.Ir.bspan "non-heading block after subtree directive";
      pop_sections_above stack 1;
      (match !stack with
       | se :: _ -> se.se_content_rev := Block block :: !(se.se_content_rev)
       | [] -> ())

    | _ (* other blocks: Paragraph, Blockquote, List, Code_block, Thematic_break, Block_embed, Display_math *) ->
      non_h1_content_seen := true;
      drop_pending_directive block.Ir.bspan "non-heading block after subtree directive";
      (match !stack with
       | se :: _ ->
         se.se_content_rev := Block block :: !(se.se_content_rev)
       | [] -> ())
  ) doc.Ir.blocks;

  (* Check for pending directive at end of document *)
  (match !pending_directive with
   | Some (dir_id, dir_span) ->
     emit TM104 (Span.Source_span dir_span)
       (Printf.sprintf "subtree directive \"%s\" at end of document without a following heading" dir_id);
     pending_directive := None
   | None -> ());

  (* Pop all remaining sections (everything except root at level 1) *)
  pop_sections_above stack 1;

  (* Extract root data *)
  let root_content =
    match !stack with
    | [se] -> List.rev !(se.se_content_rev)
    | _ -> failwith "internal error: stack corrupted - expected single root entry"
  in

  (* An untitled subtree with no content emits \subtree{}, which carries no
     information at all. *)
  let rec check_untitled content =
    List.iter (function
      | Block _ -> ()
      | Section sec ->
        if sec.title = None && sec.content = [] then
          emit TM104 (Span.Source_span sec.span)
            "untitled subtree is empty; it would emit \\subtree{}";
        check_untitled sec.content
    ) content
  in
  check_untitled root_content;

  let final_title = match !root_title with
    | Some t -> t
    | None -> [fallback_title doc_path filename]
  in

  let tree = {
    root_id;
    title = final_title;
    metadata = doc.Ir.metadata;
    content = root_content;
    span = doc.Ir.doc_span;
  } in

  Diagnostic.gate tree (List.rev !diags)

let definitions tree =
  let rec collect content acc =
    List.fold_left (fun acc item ->
      match item with
      | Block _ -> acc
      | Section (sec : section) ->
        let acc = match sec.id, sec.definition_span with
          | Some id, Some span -> { id; span } :: acc
          | _ -> acc
        in
        collect sec.content acc
    ) acc content
  in
  List.rev (collect tree.content [])
