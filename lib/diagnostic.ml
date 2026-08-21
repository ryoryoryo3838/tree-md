type severity = Error | Warning

type code =
  | TM001 | TM002 | TM003
  | TM101 | TM102 | TM103 | TM104 | TM105 | TM106 | TM107
  | TM201 | TM202 | TM203 | TM204 | TM205 | TM206
  | TM301 | TM302 | TM303 | TM304 | TM305 | TM306
  | TM401 | TM402 | TM403 | TM404 | TM500

type labelled_location = { label : string; location : Span.location }

type t = {
  severity : severity;
  code : code;
  mdbase_code : string option;
  message : string;
  primary : Span.location;
  secondary : labelled_location list;
  notes : string list;
}

let make ?(secondary = []) ?(notes = []) ?mdbase_code code primary message =
  { severity = Error; code; mdbase_code; message; primary; secondary; notes }

let warn ?(secondary = []) ?(notes = []) ?mdbase_code code primary message =
  { severity = Warning; code; mdbase_code; message; primary; secondary; notes }

let is_error diag = diag.severity = Error
let has_error diags = List.exists is_error diags

(* Warnings travel with the value; a single error discards it. Every stage
   accumulates into one list and gates once, so a file reports all of its
   diagnostics rather than stopping at the first. *)
(* [Error] here is the severity constructor, which shadows [Result.Error], so
   the result constructors are named through Stdlib. *)
let gate value diags =
  if has_error diags then Stdlib.Error diags else Stdlib.Ok (value, diags)

let severity_string = function Error -> "error" | Warning -> "warning"

let code_string = function
  | TM001 -> "TM001" | TM002 -> "TM002" | TM003 -> "TM003"
  | TM101 -> "TM101" | TM102 -> "TM102" | TM103 -> "TM103"
  | TM104 -> "TM104" | TM105 -> "TM105" | TM106 -> "TM106"
  | TM107 -> "TM107"
  | TM201 -> "TM201" | TM202 -> "TM202" | TM203 -> "TM203"
  | TM204 -> "TM204" | TM205 -> "TM205" | TM206 -> "TM206"
  | TM301 -> "TM301" | TM302 -> "TM302" | TM303 -> "TM303"
  | TM304 -> "TM304" | TM305 -> "TM305" | TM306 -> "TM306"
  | TM401 -> "TM401" | TM402 -> "TM402" | TM403 -> "TM403"
  | TM404 -> "TM404" | TM500 -> "TM500"

let location_path = function
  | Span.Source_span s -> Some s.Span.path
  | Span.Path p -> Some p
  | Span.No_location -> None

let location_start_byte = function
  | Span.Source_span s -> Some s.Span.start_byte
  | Span.Path _ | Span.No_location -> None

let location_rank = function
  | Span.Source_span _ -> 0
  | Span.Path _ -> 1
  | Span.No_location -> 2

let compare a b =
  let path_a = location_path a.primary in
  let path_b = location_path b.primary in
  let c =
    match path_a, path_b with
    | None, None -> 0
    | None, Some _ -> 1
    | Some _, None -> -1
    | Some pa, Some pb ->
      let c = String.compare pa pb in
      if c <> 0 then c
      else
        let ra = location_rank a.primary in
        let rb = location_rank b.primary in
        Int.compare ra rb
  in
  if c <> 0 then c
  else
    let ba = location_start_byte a.primary in
    let bb = location_start_byte b.primary in
    let c =
      match ba, bb with
      | None, None -> 0
      | None, Some _ -> 1
      | Some _, None -> -1
      | Some ba, Some bb -> Int.compare ba bb
    in
    if c <> 0 then c
    else
      let c = String.compare (code_string a.code) (code_string b.code) in
      if c <> 0 then c
      else String.compare a.message b.message

let expand_tabs s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    if c = '\t' then
      let col = Buffer.length buf in
      let spaces = 4 - (col mod 4) in
      for _ = 1 to spaces do Buffer.add_char buf ' ' done
    else
      Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let find_source sources path =
  List.find_opt (fun (p, _) -> p = path) sources

let render ~sources diag =
  let buf = Buffer.create 256 in
  let code = code_string diag.code in
  let loc_str =
    match diag.primary with
    | Span.Source_span s ->
      let line_col =
        match
          find_source sources s.Span.path
          |> Option.map (fun (_, src) -> Source.line_col src ~byte:s.Span.start_byte)
        with
        | Some (Ok (line, col)) ->
          Printf.sprintf "%s:%d:%d" s.Span.path line col
        | _ -> Printf.sprintf "%s:%d" s.Span.path s.Span.start_byte
      in
      line_col
    | Span.Path p -> p
    | Span.No_location -> "<no location>"
  in
  let code =
    match diag.mdbase_code with
    | None -> code
    | Some mdbase -> Printf.sprintf "%s (%s)" code mdbase
  in
  Printf.bprintf buf "%s: %s: %s\n" code
    (severity_string diag.severity) diag.message;
  Printf.bprintf buf "  --> %s\n" loc_str;
  (match diag.primary with
   | Span.Source_span s ->
     (match find_source sources s.Span.path with
      | Some (_, src) ->
        (match Source.excerpt src s with
         | Ok (text, marker) ->
           let text_expanded = expand_tabs text in
           let marker_expanded = expand_tabs marker in
           Printf.bprintf buf "   |\n";
           Printf.bprintf buf "   | %s\n" text_expanded;
           Printf.bprintf buf "   | %s\n" marker_expanded
         | Error _ -> ())
      | None -> ())
   | Span.Path _ | Span.No_location -> ());
  List.iter (fun { label; location } ->
    Printf.bprintf buf "  note: %s" label;
    (match location with
     | Span.Source_span s ->
       Printf.bprintf buf " (%s:%d)" s.Span.path s.Span.start_byte
     | Span.Path p ->
       Printf.bprintf buf " (%s)" p
     | Span.No_location -> ());
    Buffer.add_char buf '\n'
  ) diag.secondary;
  List.iter (fun note ->
    Printf.bprintf buf "  note: %s\n" note
  ) diag.notes;
  Buffer.contents buf
