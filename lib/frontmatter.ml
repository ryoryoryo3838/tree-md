type t = {
  metadata : Metadata.raw;
  masked_markdown : string;
}

(* Meta names that may be written as top-level keys instead of nested under
   `meta:`, so that an editor showing front matter as a property list can edit
   them directly. The set is closed, which keeps a misspelled name a TM101
   rather than a silently emitted `\meta{}`; `meta:` remains available for any
   name outside it. *)
let promoted_meta_keys =
  ["position"; "institution"; "venue"; "source"; "doi"; "orcid";
   "external"; "slides"; "video"; "bibtex"; "author"; "toc"; "lang"]

let reserved_keys = ["date"; "taxon"; "authors"; "contributors"; "tags"; "meta"]
let all_known_keys = reserved_keys @ promoted_meta_keys

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
    Ok { metadata = Metadata.empty; masked_markdown = text }
  else if not (text.[0] = '-' && text.[1] = '-' && text.[2] = '-') then
    Ok { metadata = Metadata.empty; masked_markdown = text }
  else
    let after_dash =
      if len > 3 && text.[3] = '\r' && len > 4 && text.[4] = '\n' then 5
      else if len > 3 && text.[3] = '\n' then 4
      else 0
    in
    if after_dash = 0 then
      Ok { metadata = Metadata.empty; masked_markdown = text }
    else
      (* Scan for closing --- on its own line (unindented).
         Use the LAST such line as the closing delimiter so that
         internal --- YAML document separators are included in the
         YAML content and can be detected as multi-document errors. *)
      let rec find_last_closing i last =
        if i >= len then last
        else if text.[i] = '-' && i + 2 < len
                && text.[i+1] = '-' && text.[i+2] = '-'
                && (i = 0 || text.[i-1] = '\n')
        then find_last_closing (i + 1) (Some i)
        else find_last_closing (i + 1) last
      in
      match find_last_closing after_dash None with
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
          Error [diag]
        | Ok yaml_parser ->
          let open Yaml.Stream in
          let diags = ref [] in
          let seen_keys = ref [] in
          let metadata = ref Metadata.empty in
          let current_key = ref None in
          let nesting = ref 0 in
          let in_authors = ref false in
          let in_contributors = ref false in
          let in_tags = ref false in
          let in_meta_key = ref false in
          let temp_meta_key = ref None in
          (* A promoted key is both the meta name and a span we must report on,
             so the key scalar has to outlive the switch to its value. *)
          let current_key_loc = ref None in
          let temp_list = ref [] in
          let doc_count = ref 0 in
          let finished = ref false in

          let emit_diag code msg start_mark end_mark =
            let loc =
              make_located source yaml_source yaml_start ""
                ~start_mark ~end_mark
            in
            diags := Diagnostic.make code (Span.Source_span loc.span) msg :: !diags
          in

          (* One meta name may be set once, whether it was written at the top
             level or under `meta:`. *)
          let add_meta (located_key : string Metadata.located) located_val
              start_mark end_mark =
            let name = located_key.Metadata.value in
            let clashes ((k : string Metadata.located), _) =
              k.Metadata.value = name
            in
            if List.exists clashes !metadata.meta then
              emit_diag TM101 ("duplicate meta key: \"" ^ name ^ "\"")
                start_mark end_mark
            else
              metadata :=
                { !metadata with meta = (located_key, located_val) :: !metadata.meta }
          in

          while not !finished do
            begin match do_parse yaml_parser with
            | Error (`Msg msg) ->
              diags := Diagnostic.make TM002
                (Span.Source_span { Span.path; start_byte = yaml_start; end_byte = yaml_start + String.length yaml_content })
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
                   emit_diag TM002 "empty YAML document" pos.start_mark pos.end_mark;
                 finished := true
               | Mapping_start { anchor; tag; _ } ->
                 if !current_key = None && !nesting >= 1 then
                   emit_diag TM101 "non-scalar mapping key is not allowed"
                     pos.start_mark pos.end_mark;
                 begin match reject_anchor anchor pos.start_mark pos.end_mark source yaml_source yaml_start with
                  | Some d -> diags := d :: !diags
                  | None -> ()
                 end;
                 begin match reject_tag tag pos.start_mark pos.end_mark source yaml_source yaml_start with
                  | Some d -> diags := d :: !diags
                  | None -> ()
                 end;
                 incr nesting
               | Mapping_end ->
                 decr nesting;
                 if !current_key = Some "meta" then current_key := None;
                 if !in_meta_key then begin
                   in_meta_key := false;
                   temp_meta_key := None
                 end
               | Sequence_start { anchor; tag; _ } ->
                 if !current_key = None && !nesting >= 1 then
                   emit_diag TM101 "non-scalar sequence key is not allowed"
                     pos.start_mark pos.end_mark;
                 begin match reject_anchor anchor pos.start_mark pos.end_mark source yaml_source yaml_start with
                  | Some d -> diags := d :: !diags
                  | None -> ()
                 end;
                 begin match reject_tag tag pos.start_mark pos.end_mark source yaml_source yaml_start with
                  | Some d -> diags := d :: !diags
                  | None -> ()
                 end
               | Sequence_end ->
                 begin match !current_key with
                  | Some "authors" ->
                    metadata := { !metadata with authors = List.rev !temp_list };
                    temp_list := [];
                    in_authors := false;
                    current_key := None
                  | Some "contributors" ->
                    metadata := { !metadata with contributors = List.rev !temp_list };
                    temp_list := [];
                    in_contributors := false;
                    current_key := None
                  | Some "tags" ->
                    let tags = List.rev !temp_list in
                    let string_tags = List.map (fun (a : Metadata.attribution) ->
                      match a with
                      | Literal lloc -> lloc
                      | Tree tloc -> { Metadata.value = tloc.Metadata.value; span = tloc.Metadata.span }
                    ) tags in
                    metadata := { !metadata with tags = string_tags };
                    temp_list := [];
                    in_tags := false;
                    current_key := None
                  | _ -> temp_list := [];
                    current_key := None
                 end
               | Alias _ ->
                 emit_diag TM101 "YAML aliases are not allowed"
                   pos.start_mark pos.end_mark
               | Scalar scalar ->
                 let anchor_reject = reject_anchor scalar.Yaml.anchor pos.start_mark pos.end_mark source yaml_source yaml_start in
                 let tag_reject = reject_tag scalar.Yaml.tag pos.start_mark pos.end_mark source yaml_source yaml_start in
                 begin match anchor_reject with Some d -> diags := d :: !diags | None -> () end;
                 begin match tag_reject with Some d -> diags := d :: !diags | None -> () end;
                 begin match !current_key with
                  | None ->
                    (* This scalar is a key *)
                    let key = scalar.Yaml.value in
                    if !nesting = 1 && not (List.mem key all_known_keys) then
                      emit_diag TM101 ("unknown front matter key: \"" ^ key ^ "\"")
                        pos.start_mark pos.end_mark;
                    if !nesting = 1 && List.mem key !seen_keys then
                      emit_diag TM101 ("duplicate front matter key: \"" ^ key ^ "\"")
                        pos.start_mark pos.end_mark;
                    if !nesting = 1 then begin
                      seen_keys := key :: !seen_keys;
                      current_key_loc :=
                        Some (make_located source yaml_source yaml_start key
                                ~start_mark:pos.start_mark ~end_mark:pos.end_mark)
                    end;
                    current_key := Some key
                  | Some key ->
                    (* This scalar is a value *)
                    begin match key with
                     | "date" ->
                       let date_str = scalar.Yaml.value in
                       if Metadata.valid_date date_str then
                         let located =
                           make_located source yaml_source yaml_start date_str
                             ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                         in
                         metadata := { !metadata with date = Some located }
                       else
                         emit_diag TM101 ("invalid date: \"" ^ date_str ^ "\"")
                           pos.start_mark pos.end_mark;
                       current_key := None
                     | "taxon" ->
                       let located =
                         make_located source yaml_source yaml_start scalar.Yaml.value
                           ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                       in
                       metadata := { !metadata with taxon = Some located };
                       current_key := None
                     | "authors" ->
                       let located =
                         make_located source yaml_source yaml_start scalar.Yaml.value
                           ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                       in
                       begin match Metadata.parse_attribution located with
                        | Ok attr ->
                          if !in_authors then
                            temp_list := attr :: !temp_list
                          else begin
                            in_authors := true;
                            temp_list := [attr]
                          end
                        | Error d ->
                          diags := d :: !diags
                       end
                     | "contributors" ->
                       let located =
                         make_located source yaml_source yaml_start scalar.Yaml.value
                           ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                       in
                       begin match Metadata.parse_attribution located with
                        | Ok attr ->
                          if !in_contributors then
                            temp_list := attr :: !temp_list
                          else begin
                            in_contributors := true;
                            temp_list := [attr]
                          end
                        | Error d ->
                          diags := d :: !diags
                       end
                     | "tags" ->
                       let located =
                         make_located source yaml_source yaml_start scalar.Yaml.value
                           ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                       in
                       if !in_tags then
                         temp_list := Metadata.Literal located :: !temp_list
                       else begin
                         in_tags := true;
                         temp_list := [Metadata.Literal located]
                       end
                     | "meta" ->
                       if !in_meta_key then begin
                         (* This is the value for a meta key *)
                         let located_val =
                           make_located source yaml_source yaml_start scalar.Yaml.value
                             ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                         in
                         begin match !temp_meta_key with
                          | Some located_key ->
                            add_meta located_key located_val
                              pos.start_mark pos.end_mark;
                            temp_meta_key := None;
                            in_meta_key := false
                          | None -> ()
                         end
                       end else begin
                         (* This is a key inside meta mapping *)
                         let located_key =
                           make_located source yaml_source yaml_start scalar.Yaml.value
                             ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                         in
                         in_meta_key := true;
                         temp_meta_key := Some located_key
                       end
                     | k when !nesting = 1 && List.mem k promoted_meta_keys ->
                       (* A top-level meta name: same destination as an entry
                          written under `meta:`, keyed by the scalar itself. *)
                       let located_val =
                         make_located source yaml_source yaml_start scalar.Yaml.value
                           ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                       in
                       begin match !current_key_loc with
                        | Some located_key ->
                          add_meta located_key located_val
                            pos.start_mark pos.end_mark
                        | None -> ()
                       end;
                       current_key_loc := None;
                       current_key := None
                     | _ ->
                       if !in_authors then begin
                         let located =
                           make_located source yaml_source yaml_start scalar.Yaml.value
                             ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                         in
                         begin match Metadata.parse_attribution located with
                          | Ok attr -> temp_list := attr :: !temp_list
                          | Error d -> diags := d :: !diags
                         end
                       end else if !in_contributors then begin
                         let located =
                           make_located source yaml_source yaml_start scalar.Yaml.value
                             ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                         in
                         begin match Metadata.parse_attribution located with
                          | Ok attr -> temp_list := attr :: !temp_list
                          | Error d -> diags := d :: !diags
                         end
                       end else if !in_tags then begin
                         let located =
                           make_located source yaml_source yaml_start scalar.Yaml.value
                             ~start_mark:pos.start_mark ~end_mark:pos.end_mark
                         in
                         temp_list := Metadata.Literal located :: !temp_list
                       end else
                         current_key := None
                    end
                 end
               | Nothing -> ()
              end
            end
          done;

          let diag_list = List.rev !diags in
          if diag_list <> [] then
            Error diag_list
          else
            let meta_rev = List.rev !metadata.meta in
            Ok { metadata = { !metadata with meta = meta_rev }; masked_markdown = masked_str }
