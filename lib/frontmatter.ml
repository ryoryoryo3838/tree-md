(* Reading front matter is two jobs, and they are kept apart.

   Parsing produces [frontmatter]: the mapping exactly as written, in the JSON
   data model, knowing nothing about what any key means. mdbase v0.3 §03 is
   explicit that front matter is an arbitrary mapping, so a key this compiler
   has no use for is carried rather than rejected.

   Interpretation is a separate pass: Metadata.of_yaml reads the keys tree-md
   emits out of that mapping, and it happens in the compiler, where the
   collection's own settings are known. *)
type t = {
  frontmatter : Yaml_json.t option;
  masked_markdown : string;
}

(* The events arrive as a stream, so the tree is assembled with an explicit
   stack rather than by recursion. *)
type frame =
  | Mapping of {
      mutable entries : Yaml_json.field list;
      mutable pending : (string * Span.t) option;
      start : Yaml.Stream.Mark.t;
    }
  | Sequence of {
      mutable items : Yaml_json.t list;
      start : Yaml.Stream.Mark.t;
    }

let trim_crlf_end s =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '\n' then
    let start = if len > 1 && s.[len - 2] = '\r' then len - 2 else len - 1 in
    String.sub s 0 start
  else
    s

(* Convert a YAML Mark character index to a byte offset in the original source *)
let yaml_char_to_source_byte yaml_source yaml_start_byte char_index =
  match Source.character_to_byte yaml_source ~character:char_index with
  | Some byte -> yaml_start_byte + byte
  | None ->
    yaml_start_byte + Source.length yaml_source

let make_span source yaml_source yaml_start_byte ~start_mark ~end_mark =
  let open Yaml.Stream in
  let start_byte = yaml_char_to_source_byte yaml_source yaml_start_byte start_mark.Mark.index in
  let end_byte = yaml_char_to_source_byte yaml_source yaml_start_byte end_mark.Mark.index in
  Source.span source ~start_byte ~end_byte

let make_located source yaml_source yaml_start_byte value ~start_mark ~end_mark =
  match make_span source yaml_source yaml_start_byte ~start_mark ~end_mark with
  | Ok span -> { Metadata.value; span }
  | Error _ ->
    let sp = { Span.path = Source.path source; start_byte = yaml_start_byte; end_byte = yaml_start_byte } in
    { Metadata.value; span = sp }

let reject_anchor anchor start_mark end_mark source yaml_source yaml_start_byte =
  match anchor with
  | Some _ ->
    let loc =
      make_located source yaml_source yaml_start_byte ""
        ~start_mark ~end_mark
    in
    Some (Diagnostic.make TM101
      (Span.Source_span loc.span)
      "YAML anchors are not allowed in front matter")
  | None -> None

let reject_tag tag start_mark end_mark source yaml_source yaml_start_byte =
  match tag with
  | Some _ ->
    let loc =
      make_located source yaml_source yaml_start_byte ""
        ~start_mark ~end_mark
    in
    Some (Diagnostic.make TM101
      (Span.Source_span loc.span)
      "YAML tags are not allowed in front matter")
  | None -> None

let make_source_for_yaml source yaml_start yaml_content =
  match Source.of_string ~path:(Source.path source) yaml_content with
  | Ok src -> Ok src
  | Error { byte = _ } ->
    let diag =
      Diagnostic.make TM002
        (Span.Source_span
           { Span.path = Source.path source; start_byte = yaml_start;
             end_byte = yaml_start + String.length yaml_content })
        "invalid UTF-8 in extracted YAML content"
    in
    Error [diag]

let parse source =
  let text = Source.text source in
  let len = String.length text in
  let path = Source.path source in

  (* Check for opening --- at byte 0 *)
  if len < 4 then
    Ok ({ frontmatter = None; masked_markdown = text }, [])
  else if not (text.[0] = '-' && text.[1] = '-' && text.[2] = '-') then
    Ok ({ frontmatter = None; masked_markdown = text }, [])
  else
    let after_dash =
      if len > 3 && text.[3] = '\r' && len > 4 && text.[4] = '\n' then 5
      else if len > 3 && text.[3] = '\n' then 4
      else 0
    in
    if after_dash = 0 then
      Ok ({ frontmatter = None; masked_markdown = text }, [])
    else
      (* Scan for the closing `---`: the FIRST line after the opening that is
         exactly three dashes, unindented, with nothing after them but
         whitespace. Front matter ends at the first fence in Obsidian, Jekyll,
         Hugo and pandoc alike, and taking any later one would swallow the
         `---` a note writes as a thematic break — the highest-blast-radius
         single character in the language, since the whole body would then be
         read as YAML. A later `---` is now an ordinary thematic break. *)
      let line_is_fence i =
        (i = 0 || text.[i - 1] = '\n')
        && i + 2 < len
        && text.[i] = '-' && text.[i + 1] = '-' && text.[i + 2] = '-'
        && (let rec only_blanks j =
              if j >= len then true
              else
                match text.[j] with
                | ' ' | '\t' | '\r' -> only_blanks (j + 1)
                | '\n' -> true
                | _ -> false
            in
            only_blanks (i + 3))
      in
      let rec find_first_closing i =
        if i >= len then None
        else if line_is_fence i then Some i
        else find_first_closing (i + 1)
      in
      match find_first_closing after_dash with
      | None ->
        let diag =
          Diagnostic.make TM002
            (Span.Source_span
               { Span.path; start_byte = 0; end_byte = len })
            "missing closing `---` delimiter"
        in
        Error [diag]
      | Some closing_start ->
        let closing_end =
          if closing_start + 3 < len && text.[closing_start+3] = '\r'
             && closing_start + 4 < len && text.[closing_start+4] = '\n'
          then closing_start + 5
          else if closing_start + 3 < len && text.[closing_start+3] = '\n' then
            closing_start + 4
          else
            closing_start + 3
        in

        (* Build masked markdown *)
        let masked = Bytes.create len in
        for i = 0 to closing_end - 1 do
          let c = text.[i] in
          if c = '\r' || c = '\n' then Bytes.set masked i c
          else Bytes.set masked i ' '
        done;
        for i = closing_end to len - 1 do
          Bytes.set masked i text.[i]
        done;
        let masked_str = Bytes.unsafe_to_string masked in

        (* Extract YAML content between delimiters *)
        let yaml_start = after_dash in
        let yaml_content_raw = String.sub text yaml_start (closing_start - yaml_start) in
        let yaml_content = trim_crlf_end yaml_content_raw in

        let yaml_source_result = make_source_for_yaml source yaml_start yaml_content in

        (* Parse YAML events *)
        match yaml_source_result with
        | Error diags -> Error diags
        | Ok yaml_source ->
        match Yaml.Stream.parser yaml_content with
        | Error (`Msg msg) ->
          let diag =
            Diagnostic.make TM002
              (Span.Source_span { Span.path; start_byte = yaml_start; end_byte = yaml_start + String.length yaml_content })
              ("YAML parse error: " ^ msg)
          in
          Error [diag]        | Ok yaml_parser ->
          let open Yaml.Stream in
          let diags = ref [] in
          let doc_count = ref 0 in
          let finished = ref false in

          let span_of start_mark end_mark =
            (make_located source yaml_source yaml_start ""
               ~start_mark ~end_mark).Metadata.span
          in
          let emit_diag code msg start_mark end_mark =
            diags :=
              Diagnostic.make code
                (Span.Source_span (span_of start_mark end_mark)) msg
              :: !diags
          in
          let reject_decoration anchor tag start_mark end_mark =
            (match reject_anchor anchor start_mark end_mark source yaml_source
                     yaml_start with
             | Some d -> diags := d :: !diags
             | None -> ());
            match reject_tag tag start_mark end_mark source yaml_source
                    yaml_start with
            | Some d -> diags := d :: !diags
            | None -> ()
          in

          (* The events arrive as a stream, so the tree is assembled with an
             explicit stack. A mapping frame remembers the key it is waiting
             for a value for; everything else is append-and-pop. *)
          let stack = ref [] in
          let root = ref None in

          let place ?text (node : Yaml_json.t) ~start_mark ~end_mark =
            match !stack with
            | [] -> if !root = None then root := Some node
            | Sequence frame :: _ -> frame.items <- node :: frame.items
            | Mapping frame :: _ -> (
              match frame.pending with
              | None -> (
                match text with
                | None ->
                  emit_diag TM101 "non-scalar mapping key is not allowed"
                    start_mark end_mark
                | Some name ->
                  if
                    List.exists
                      (fun (f : Yaml_json.field) -> String.equal f.Yaml_json.name name)
                      frame.entries
                  then
                    emit_diag TM101
                      ("duplicate front matter key: \"" ^ name ^ "\"")
                      start_mark end_mark;
                  frame.pending <- Some (name, node.Yaml_json.span))
              | Some (name, name_span) ->
                frame.pending <- None;
                frame.entries <-
                  { Yaml_json.name; name_span; value = node } :: frame.entries)
          in

          let close_container build ~end_mark =
            match !stack with
            | Mapping frame :: rest when build = `Mapping ->
              stack := rest;
              (* A key whose value the document never supplied is null, which
                 is what YAML itself means by `a:` with nothing after it. *)
              (match frame.pending with
               | Some (name, name_span) ->
                 frame.entries <-
                   { Yaml_json.name; name_span;
                     value = { Yaml_json.value = Yaml_json.Null; text = None;
                               span = name_span } }
                   :: frame.entries
               | None -> ());
              let span = span_of frame.start end_mark in
              place
                { Yaml_json.value = Yaml_json.Assoc (List.rev frame.entries);
                  text = None; span }
                ~start_mark:frame.start ~end_mark
            | Sequence frame :: rest when build = `Sequence ->
              stack := rest;
              let span = span_of frame.start end_mark in
              place
                { Yaml_json.value = Yaml_json.List (List.rev frame.items);
                  text = None; span }
                ~start_mark:frame.start ~end_mark
            | _ ->
              emit_diag TM002 "unbalanced YAML document" end_mark end_mark
          in

          while not !finished do
            begin match do_parse yaml_parser with
            | Error (`Msg msg) ->
              diags := Diagnostic.make TM002
                (Span.Source_span
                   { Span.path; start_byte = yaml_start;
                     end_byte = yaml_start + String.length yaml_content })
                ("YAML parse error: " ^ msg) :: !diags;
              finished := true
            | Ok (event, pos) ->
              begin match event with
               | Stream_start _ -> ()
               | Document_start _ ->
                 incr doc_count;
                 if !doc_count > 1 then
                   emit_diag TM002 "multiple YAML documents are not allowed"
                     pos.start_mark pos.end_mark
               | Document_end _ -> ()
               | Stream_end ->
                 if !doc_count = 0 then
                   emit_diag TM002 "empty YAML document"
                     pos.start_mark pos.end_mark;
                 finished := true
               | Mapping_start { anchor; tag; _ } ->
                 reject_decoration anchor tag pos.start_mark pos.end_mark;
                 stack :=
                   Mapping { entries = []; pending = None; start = pos.start_mark }
                   :: !stack
               | Mapping_end -> close_container `Mapping ~end_mark:pos.end_mark
               | Sequence_start { anchor; tag; _ } ->
                 reject_decoration anchor tag pos.start_mark pos.end_mark;
                 stack :=
                   Sequence { items = []; start = pos.start_mark } :: !stack
               | Sequence_end -> close_container `Sequence ~end_mark:pos.end_mark
               | Nothing -> ()
               | Alias _ ->
                 emit_diag TM101 "YAML aliases are not allowed"
                   pos.start_mark pos.end_mark
               | Scalar scalar ->
                 reject_decoration scalar.Yaml.anchor scalar.Yaml.tag
                   pos.start_mark pos.end_mark;
                 let span = span_of pos.start_mark pos.end_mark in
                 (* Only a plain scalar is resolved by YAML's core schema; a
                    quoted one is a string whatever it looks like. *)
                 let value =
                   if scalar.Yaml.style = `Plain && scalar.Yaml.plain_implicit
                   then
                     match Yaml_json.of_plain_scalar scalar.Yaml.value with
                     | Ok value -> value
                     | Error message ->
                       emit_diag TM002 message pos.start_mark pos.end_mark;
                       Yaml_json.String scalar.Yaml.value
                   else Yaml_json.String scalar.Yaml.value
                 in
                 place ~text:scalar.Yaml.value
                   { Yaml_json.value; text = Some scalar.Yaml.value; span }
                   ~start_mark:pos.start_mark ~end_mark:pos.end_mark
              end
            end
          done;

          (* mdbase v0.3 §03: front matter must parse to a mapping. *)
          let frontmatter =
            match !root with
            | None -> None
            | Some ({ Yaml_json.value = Yaml_json.Assoc _; _ } as node) -> Some node
            | Some node ->
              diags :=
                Diagnostic.make TM002 (Span.Source_span node.Yaml_json.span)
                  ("front matter must be a mapping, but this is "
                   ^ Yaml_json.describe node.Yaml_json.value)
                :: !diags;
              None
          in
          Diagnostic.gate
            { frontmatter; masked_markdown = masked_str }
            (List.rev !diags)
