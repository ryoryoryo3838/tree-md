type section = {
  id : string option;
  definition_span : Span.t option;
  title : Ir.inline list;
  body : Ir.block list;
  children : section list;
  span : Span.t;
}

type t = {
  root_id : string;
  title : Ir.inline list;
  metadata : Ir.inline list Metadata.t;
  body : Ir.block list;
  sections : section list;
  span : Span.t;
}

type definition = { id : string; span : Span.t }

type stack_entry = {
  se_level : int;
  se_id : string option;
  se_def_span : Span.t option;
  se_title : Ir.inline list;
  se_heading_span : Span.t;
  se_body_rev : Ir.block list ref;
  se_children_rev : section list ref;
}

let zero_span path =
  match Span.make ~path ~start_byte:0 ~end_byte:0 with
  | Ok s -> s | Error _ -> failwith "cannot create zero span"

let fallback_title path root_id =
  { Ir.node = Ir.Text root_id; Ir.span = zero_span path }

let section_span se body (children : section list) =
  let spans = se.se_heading_span :: (List.map (fun b -> b.Ir.bspan) body) @ (List.map (fun (c : section) -> c.span) children) in
  let end_byte = List.fold_left (fun acc s -> max acc s.Span.end_byte) se.se_heading_span.Span.end_byte spans in
  match Span.make ~path:se.se_heading_span.Span.path ~start_byte:se.se_heading_span.Span.start_byte ~end_byte with
  | Ok s -> s | Error _ -> se.se_heading_span

let finalize_stack_entry (se : stack_entry) =
  let body = List.rev !(se.se_body_rev) in
  let children = List.rev !(se.se_children_rev) in
  let span = section_span se body children in
  { id = se.se_id; definition_span = se.se_def_span;
    title = se.se_title; body; children; span }

let push_stack_entry stack level id_opt def_span_opt title heading_span =
  stack := { se_level = level; se_id = id_opt; se_def_span = def_span_opt;
             se_title = title; se_heading_span = heading_span;
             se_body_rev = ref []; se_children_rev = ref [] } :: !stack

let pop_sections_above stack n =
  let rec loop () =
    match !stack with
    | se :: rest when se.se_level > n ->
      let finalized = finalize_stack_entry se in
      stack := rest;
      (match !stack with
       | parent :: _ ->
         parent.se_children_rev := finalized :: !(parent.se_children_rev)
       | [] -> ());
      loop ()
    | _ -> ()
  in
  loop ()

let pop_sections_ge stack n =
  let rec loop () =
    match !stack with
    | se :: rest when se.se_level >= n ->
      let finalized = finalize_stack_entry se in
      stack := rest;
      (match !stack with
       | parent :: _ ->
         parent.se_children_rev := finalized :: !(parent.se_children_rev)
       | [] -> ());
      loop ()
    | _ -> ()
  in
  loop ()

let build ~root_id (doc : Ir.document) =
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
  push_stack_entry stack 1 None None [] doc.Ir.doc_span;

  List.iter (fun (block : Ir.block) ->
    match block.Ir.bnode with
    | Ir.Heading { level = 1; title } ->
      if !root_title <> None then
        emit TM103 (Span.Source_span block.Ir.bspan) "duplicate H1 heading"
      else if !non_h1_content_seen then
        emit TM103 (Span.Source_span block.Ir.bspan) "H1 heading must be the first block in the document"
      else begin
        (match !pending_directive with
         | Some _ ->
           emit TM104 (Span.Source_span block.Ir.bspan) "subtree directive before H1 heading";
           pending_directive := None
         | None -> ());
        root_title := Some title
      end

    | Ir.Heading { level; title } ->
      non_h1_content_seen := true;
      (* Pop all sections at level >= this level *)
      pop_sections_ge stack level;
      (* Check parent level *)
      let parent_level = (match !stack with se :: _ -> se.se_level | [] -> 1) in
      if parent_level < level - 1 then
        emit TM103 (Span.Source_span block.Ir.bspan)
          (Printf.sprintf "heading level %d follows level %d (level skipped; expected level %d)"
             level parent_level (parent_level + 1));
      (* Consume pending directive *)
      let id_opt, def_span_opt = match !pending_directive with
        | Some (dir_id, dir_span) ->
          pending_directive := None;
          (Some dir_id, Some dir_span)
        | None -> (None, None)
      in
      push_stack_entry stack level id_opt def_span_opt title block.Ir.bspan

    | Ir.Subtree_directive id ->
      (* Directives do not count as content for H1-first rule *)
      (match !pending_directive with
       | Some (prev_id, _) ->
         emit TM104 (Span.Source_span block.Ir.bspan)
           (Printf.sprintf "multiple subtree directives without a heading (previous directive \"%s\" lost)" prev_id)
       | None -> ());
      pending_directive := Some (id, block.Ir.bspan)

    | _ (* other blocks: Paragraph, Blockquote, List, Code_block, Thematic_break, Block_embed, Display_math *) ->
      non_h1_content_seen := true;
      (match !pending_directive with
       | Some _ ->
         emit TM104 (Span.Source_span block.Ir.bspan) "non-heading block after subtree directive";
         pending_directive := None
       | None -> ());
      (match !stack with
       | se :: _ ->
         se.se_body_rev := block :: !(se.se_body_rev)
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
  let root_body, root_sections_rev =
    match !stack with
    | [se] -> (List.rev !(se.se_body_rev), !(se.se_children_rev))
    | _ -> failwith "internal error: stack corrupted - expected single root entry"
  in

  let final_title = match !root_title with
    | Some t -> t
    | None -> [fallback_title doc_path root_id]
  in

  let tree = {
    root_id;
    title = final_title;
    metadata = doc.Ir.metadata;
    body = root_body;
    sections = List.rev root_sections_rev;
    span = doc.Ir.doc_span;
  } in

  match !diags with
  | [] -> Ok tree
  | ds -> Error (List.rev ds)

let definitions tree =
  let rec collect (secs : section list) acc =
    List.fold_left (fun acc (sec : section) ->
      let acc = match sec.id, sec.definition_span with
        | Some id, Some span -> { id; span } :: acc
        | _ -> acc
      in
      collect sec.children acc
    ) acc secs
  in
  List.rev (collect tree.sections [])
