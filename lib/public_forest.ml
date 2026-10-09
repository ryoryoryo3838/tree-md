type error = Invalid_json | Schema | Invalid_id | Duplicate_id | Invalid_date
           | Unsafe_markdown | Missing_target | Cycle | Limit | Io | Unsafe_output
type t = Yojson.Safe.t list
let error_code = function
 | Invalid_json -> "PF_JSON" | Schema -> "PF_SCHEMA" | Invalid_id -> "PF_ID"
 | Duplicate_id -> "PF_DUPLICATE_ID" | Invalid_date -> "PF_DATE"
 | Unsafe_markdown -> "PF_MARKDOWN" | Missing_target -> "PF_TARGET"
 | Cycle -> "PF_CYCLE" | Limit -> "PF_LIMIT" | Io -> "PF_IO"
 | Unsafe_output -> "PF_OUTPUT"
exception Reject of error
let fail e = raise (Reject e)
let protect f = try Ok (f ()) with Reject e -> Error e | Stack_overflow -> Error Limit
let member k = function `Assoc xs -> (try List.assoc k xs with Not_found -> fail Schema) | _ -> fail Schema
let max_json_bytes = 8 * 1024 * 1024
let max_json_depth = 128
let max_tree_depth = 32
let max_chunk_bytes = 256 * 1024
let string = function
  | `String s ->
    if String.length s > max_chunk_bytes then fail Limit;
    if String.exists (fun c -> (Char.code c < 0x20 && not (List.mem c ['\t';'\n';'\r'])) || Char.code c=0x7f) s
    then fail Schema;
    (match Source.of_string ~path:"<public-value>" s with Ok _ -> () | Error _ -> fail Invalid_json);
    s
  | _ -> fail Schema
(* Reject Yojson's permissive extensions before allocating its recursive AST. *)
let json_preflight text =
  let len = String.length text in
  if len > max_json_bytes then fail Limit;
  (match Source.of_string ~path:"<public-json>" text with Ok _ -> () | Error _ -> fail Invalid_json);
  let pos = ref 0 and tokens = ref 0 in
  let error () = fail Invalid_json in
  let whitespace () = while !pos < len && List.mem text.[!pos] [' ';'\t';'\n';'\r'] do incr pos done in
  let expect c = if !pos >= len || text.[!pos] <> c then error (); incr pos in
  let hex c = match c with
    | '0'..'9' -> Char.code c-Char.code '0'
    | 'a'..'f' -> Char.code c-Char.code 'a'+10
    | 'A'..'F' -> Char.code c-Char.code 'A'+10
    | _ -> error () in
  let unicode () =
    if !pos+4 > len then error ();
    let value = ref 0 in
    for _=1 to 4 do value := !value*16 + hex text.[!pos]; incr pos done;
    !value in
  let quoted () =
    expect '"';
    let closed = ref false in
    while not !closed && !pos < len do
      let c=text.[!pos] in incr pos;
      if c='"' then closed:=true
      else if Char.code c < 0x20 then error ()
      else if c='\\' then begin
        if !pos >= len then error ();
        let esc=text.[!pos] in incr pos;
        match esc with
        | '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' -> ()
        | 'u' ->
          let value=unicode () in
          if value>=0xd800 && value<=0xdbff then begin
            expect '\\'; expect 'u';
            let low=unicode () in if low<0xdc00 || low>0xdfff then error ()
          end else if value>=0xdc00 && value<=0xdfff then error ()
        | _ -> error ()
      end
    done;
    if not !closed then error () in
  let number () =
    if !pos < len && text.[!pos]='-' then incr pos;
    if !pos>=len then error ();
    let digits () = while !pos<len && text.[!pos]>='0' && text.[!pos]<='9' do incr pos done in
    if text.[!pos]='0' then incr pos
    else if text.[!pos]>='1' && text.[!pos]<='9' then digits () else error ();
    let mandatory_digits () = let start= !pos in digits (); if !pos=start then error () in
    if !pos<len && text.[!pos]='.' then begin incr pos; mandatory_digits () end;
    if !pos<len && List.mem text.[!pos] ['e';'E'] then begin
      incr pos; if !pos<len && List.mem text.[!pos] ['+';'-'] then incr pos;
      mandatory_digits ()
    end in
  let rec value depth =
    if depth > max_json_depth then fail Limit;
    incr tokens; if !tokens>200000 then fail Limit;
    whitespace (); if !pos>=len then error ();
    match text.[!pos] with
    | '"' -> quoted ()
    | '{' ->
      incr pos; whitespace ();
      if !pos<len && text.[!pos]='}' then incr pos
      else begin
        let rec entries () =
          whitespace (); quoted (); whitespace (); expect ':'; value (depth+1); whitespace ();
          if !pos<len && text.[!pos]=',' then begin incr pos; entries () end else expect '}' in
        entries ()
      end
    | '[' ->
      incr pos; whitespace ();
      if !pos<len && text.[!pos]=']' then incr pos
      else begin
        let rec entries () =
          value (depth+1); whitespace ();
          if !pos<len && text.[!pos]=',' then begin incr pos; entries () end else expect ']' in
        entries ()
      end
    | 't' | 'f' | 'n' ->
      let literal = match text.[!pos] with 't' -> "true" | 'f' -> "false" | _ -> "null" in
      String.iter expect literal
    | '-' | '0'..'9' -> number ()
    | _ -> error () in
  value 0; whitespace (); if !pos<>len then error ()
let list = function `List xs -> xs | _ -> fail Schema
let object_fields allowed required json =
  let xs = match json with `Assoc xs -> xs | _ -> fail Schema in
  let seen = Hashtbl.create 16 in
  List.iter (fun (k, _) ->
    if not (List.mem k allowed) || Hashtbl.mem seen k then fail Schema;
    Hashtbl.add seen k ()) xs;
  List.iter (fun k -> if not (Hashtbl.mem seen k) then fail Schema) required;
  xs
let valid_id s =
  s <> "" && String.for_all (function
    | 'A'..'Z' | 'a'..'z' | '0'..'9' | '-' -> true | _ -> false) s
let id json = let s = string json in
  if not (valid_id s) then fail Invalid_id;
  if String.length s > 250 then fail Limit; s
let boolean = function `Bool b -> b | _ -> fail Schema
let property_keys = ["position"; "institution"; "venue"; "source"; "doi";
  "orcid"; "external"; "slides"; "video"; "bibtex"; "author"]
let starts prefix s = String.starts_with ~prefix s
let safe_http s =
  let n = if starts "https://" s then 8 else if starts "http://" s then 7 else 0 in
  n > 0 && String.length s > n && s.[n] <> '/' && s.[n] <> '?' && s.[n] <> '#'
  && String.for_all (fun c -> Char.code c > 0x20 && Char.code c <> 0x7f
    && not (List.mem c ['\\'; '<'; '>'; '"'; '\''])) s
(* Validate without trimming, decoding, case repair, or registry lookup. Only
   the emission value loses an exact official resolver prefix; wire values and
   identifiers retain their spelling. The renderer adds its own HTTPS prefix. *)
let native_property key value =
  let hosts = match key with
    | "doi" -> ["doi.org"; "www.doi.org"; "dx.doi.org"]
    | "orcid" -> ["orcid.org"]
    | _ -> [] in
  let prefixes = List.concat_map (fun host ->
    ["https://" ^ host ^ "/"; "http://" ^ host ^ "/"]) hosts in
  let native = match List.find_opt (fun prefix -> starts prefix value) prefixes with
    | None -> value
    | Some prefix -> String.sub value (String.length prefix)
        (String.length value - String.length prefix) in
  let digit c = c >= '0' && c <= '9' in
  let valid = match key with
    | "doi" ->
      starts "10." native &&
      (match String.index_opt native '/' with
       | Some slash when slash >= 7 && slash <= 12 && slash+1 < String.length native ->
         String.for_all digit (String.sub native 3 (slash-3)) &&
         String.for_all (function
           | 'a'..'z' | 'A'..'Z' | '0'..'9' | '-' | '.' | '_' | ';'
           | '(' | ')' | '/' | ':' | '+' -> true | _ -> false)
           (String.sub native (slash+1) (String.length native-slash-1))
       | _ -> false)
    | "orcid" ->
      String.length native=19 &&
      let good = ref true in
      String.iteri (fun i c ->
        if not (if List.mem i [4;9;14] then c='-'
          else digit c || (i=18 && c='X')) then good:=false) native;
      !good
    | _ -> true in
  if not valid then fail Schema;
  native
let validate_schema json =
  ignore (object_fields ["schema";"trees";"assets"] ["schema";"trees";"assets"] json);
  if string (member "schema" json) <> "forester-public-v2" then fail Schema;
  if list (member "assets" json) <> [] then fail Schema;
  let identities = Hashtbl.create 32 in
  let budget = ref 0 in
  let tick () = incr budget; if !budget>20000 then fail Limit in
  let strings json = List.iter (fun x -> ignore (string x)) (list json) in
  let attribution json =
    match string (member "kind" json) with
    | "literal" -> ignore (object_fields ["kind";"value"] ["kind";"value"] json);
      ignore (string (member "value" json))
    | "tree" -> ignore (object_fields ["kind";"id"] ["kind";"id"] json);
      ignore (id (member "id" json))
    | _ -> fail Schema in
  let rec tree ~top depth json =
    tick (); if depth>max_tree_depth then fail Limit;
    let required = ["title";"authors";"dates";"contributors";"properties";"citationAuthors";"content"] in
    let fields = object_fields ("id"::"taxon"::"publicationYear"::required)
      (if top then "id"::required else required) json in
    (match List.assoc_opt "id" fields with
     | None -> () | Some value ->
       let value = id value in
       let key = String.lowercase_ascii value in
       if Hashtbl.mem identities key then fail Duplicate_id;
       Hashtbl.add identities key ());
    ignore (string (member "title" json));
    List.iter (fun key -> Option.iter (fun v -> ignore (string v)) (List.assoc_opt key fields))
      ["taxon";"publicationYear"];
    List.iter (fun key -> List.iter attribution (list (member key json))) ["authors";"contributors"];
    List.iter (fun key -> strings (member key json)) ["dates";"citationAuthors"];
    List.iter (fun d -> let d = string d in
      if String.length d <> 10 || not (Metadata.valid_date d) || starts "0000" d then fail Invalid_date)
      (list (member "dates" json));
    let props = object_fields property_keys [] (member "properties" json) in
    List.iter (fun (k,v) ->
      strings v;
      if List.mem k ["doi";"orcid"] then
        List.iter (fun s -> ignore (native_property k (string s))) (list v);
      if List.mem k ["external";"slides";"video"] then
        List.iter (fun s -> if not (safe_http (string s)) then fail Schema) (list v)) props;
    List.iter (node depth) (list (member "content" json))
  and node depth json =
    tick ();
    match string (member "kind" json) with
    | "markdown" -> ignore (object_fields ["kind";"text"] ["kind";"text"] json);
      ignore (string (member "text" json))
    | "subtree" -> ignore (object_fields ["kind";"tree"] ["kind";"tree"] json);
      tree ~top:false (depth+1) (member "tree" json)
    | "transclude" ->
      ignore (object_fields ["kind";"id";"header";"toc"] ["kind";"id";"header";"toc"] json);
      ignore (id (member "id" json));
      List.iter (fun k -> ignore (boolean (member k json))) ["header";"toc"]
    | _ -> fail Schema in
  let roots = list (member "trees" json) in
  List.iter (tree ~top:true 0) roots;
  roots
let of_string text = protect (fun () ->
  json_preflight text;
  let json = try Yojson.Safe.from_string text with Yojson.Json_error _ -> fail Invalid_json in
  validate_schema json)
let contains s needle = Re.execp (Re.compile (Re.str needle)) s
let safe_label s =
  s <> "" && String.for_all (fun c -> Char.code c >= 0x20 && Char.code c <> 0x7f
    && not (List.mem c ['[';']';'|';'\\';'`';'$';'%';'<';'>'])) s
let safe_tex tex =
  let depth = ref 0 and good = ref true and i = ref 0 in
  let banned = ["title";"taxon";"date";"meta";"author";"contributor";"subtree";
    "transclude";"import";"export";"namespace";"open";"scope";"put";"get";"def";
    "let";"alloc";"fun";"object";"patch";"call";"execute";"query";"tex";"input";
    "include";"includegraphics";"write";"href";"url";"htmlClass";"htmlId";"htmlStyle";"htmlData"] in
  while !i < String.length tex do
    (match tex.[!i] with
     | '\\' when !i + 1 < String.length tex ->
       incr i;
       if (tex.[!i] >= 'a' && tex.[!i] <= 'z') || (tex.[!i] >= 'A' && tex.[!i] <= 'Z') then begin
         let start = !i in
         while !i < String.length tex && ((tex.[!i] >= 'a' && tex.[!i] <= 'z') || (tex.[!i] >= 'A' && tex.[!i] <= 'Z')) do incr i done;
         if List.mem (String.sub tex start (!i-start)) banned then good := false;
         decr i
       end
     | '{' -> incr depth
     | '}' -> decr depth; if !depth < 0 then good := false
     | _ -> ());
    incr i
  done;
  if not !good || !depth <> 0 then fail Unsafe_markdown
let guard_markdown source text =
  let masked = Bytes.of_string text in
  let mark meta =
    let loc = Cmarkit.Meta.textloc meta in
    if not (Cmarkit.Textloc.is_none loc) then
      for i = max 0 (Cmarkit.Textloc.first_byte loc) to min (String.length text-1) (Cmarkit.Textloc.last_byte loc) do
        Bytes.set masked i ' '
      done in
  let count = ref 0 in
  let tick () = incr count; if !count > 20000 then fail Limit in
  let block _ acc = function
    | Cmarkit.Block.Code_block (_,meta) -> tick (); mark meta; `Fold acc
    | Cmarkit.Block.Heading _ | Cmarkit.Block.Html_block _
    | Cmarkit.Block.Link_reference_definition _ -> fail Unsafe_markdown
    | _ -> tick (); `Default in
  let inline _ acc = function
    | Cmarkit.Inline.Code_span (_,meta) | Cmarkit.Inline.Ext_math_span (_,meta) ->
      tick (); mark meta; `Fold acc
    | Cmarkit.Inline.Raw_html _ -> fail Unsafe_markdown
    | _ -> tick (); `Default in
  let doc = Cmarkit.Doc.of_string ~locs:true ~strict:false ~resolver:(Wiki.resolver source) text in
  ignore (Cmarkit.Folder.fold_doc (Cmarkit.Folder.make ~block ~inline ()) () doc);
  let raw = Bytes.to_string masked in
  let stripped = String.trim raw in
  if starts "---" stripped || starts "+++" stripped then fail Unsafe_markdown;
  let len = String.length raw and i = ref 0 in
  let is_id_char = function 'A'..'Z' | 'a'..'z' | '0'..'9' | '-' -> true | _ -> false in
  while !i < len do
    if !i+1 < len && raw.[!i]='[' && raw.[!i+1]='[' then begin
      if !i > 0 && raw.[!i-1]='!' then fail Unsafe_markdown;
      let start = !i+2 in
      let stop = ref start in
      while !stop+1 < len && not (raw.[!stop]=']' && raw.[!stop+1]=']') do
        if raw.[!stop]='\n' || raw.[!stop]='\r' then fail Unsafe_markdown;
        incr stop
      done;
      if !stop+1 >= len then fail Unsafe_markdown;
      let body = String.sub raw start (!stop-start) in
      (match String.split_on_char '|' body with
       | [target;label] when valid_id target && safe_label label -> ()
       | _ -> fail Unsafe_markdown);
      i := !stop+2
    end else begin
      if !i+1 < len && List.exists (fun token -> !i+String.length token <= len
        && String.sub raw !i (String.length token)=token) ["]]";"%%";"#{";"\\{";"<!--"]
      then fail Unsafe_markdown;
      if raw.[!i]='\\' && !i+1 < len &&
        ((raw.[!i+1]>='A' && raw.[!i+1]<='Z') || (raw.[!i+1]>='a' && raw.[!i+1]<='z') || raw.[!i+1]='<')
      then fail Unsafe_markdown;
      if raw.[!i]='^' && (!i=0 || List.mem raw.[!i-1] [' ';'\t';'\n']) then begin
        let stop = ref (!i+1) in
        while !stop < len && is_id_char raw.[!stop] do incr stop done;
        let tail = ref !stop in
        while !tail < len && List.mem raw.[!tail] [' ';'\t';'\r'] do incr tail done;
        if !stop > !i+1 && (!tail=len || raw.[!tail]='\n') then fail Unsafe_markdown
      end;
      incr i
    end
  done
let validate_blocks blocks =
  let rec inlines xs =
    let check_text text =
      if List.exists (contains text) ["[[";"]]";"%%";"<!--";"\\{"] then fail Unsafe_markdown in
    let rec runs pending = function
      | [] -> check_text (String.concat "" (List.rev pending))
      | {Ir.node=Ir.Text s; _}::rest -> runs (s::pending) rest
      | _::rest -> check_text (String.concat "" (List.rev pending)); runs [] rest in
    runs [] xs;
    List.iter (fun il -> match il.Ir.node with
      | Ir.Text _ | Ir.Code _ | Ir.Footnote_ref _ | Ir.Hard_break | Ir.Soft_break -> ()
      | Ir.Emphasis xs | Ir.Strong xs | Ir.Strikethrough xs | Ir.Highlight xs -> inlines xs
      | Ir.Wiki_link {target;alias=Some alias} when valid_id target && safe_label alias -> ()
      | Ir.Link {label;destination;_} ->
        if not (valid_id destination || safe_http destination || starts "mailto:" destination) then fail Unsafe_markdown;
        inlines label
      | Ir.Math {tex; _} -> safe_tex tex
      | Ir.Wiki_link _ | Ir.Wiki_embed _ | Ir.Image _ -> fail Unsafe_markdown) xs
  and block b = match b.Ir.bnode with
    | Ir.Paragraph xs -> inlines xs
    | Ir.Blockquote bs -> List.iter block bs
    | Ir.List {items; _} -> List.iter (fun i -> List.iter block i.Ir.item_blocks) items
    | Ir.Table {header;rows;_} -> Option.iter (List.iter inlines) header; List.iter (List.iter inlines) rows
    | Ir.Callout {title;body;_} -> inlines title; List.iter block body
    | Ir.Footnotes entries -> List.iter (fun (_,bs) -> List.iter block bs) entries
    | Ir.Display_math tex -> safe_tex tex
    | Ir.Code_block _ | Ir.Thematic_break -> ()
    | Ir.Heading _ | Ir.Subtree_directive _ | Ir.Subtree_open _ | Ir.Subtree_close _
    | Ir.Block_embed _ | Ir.Card_link _ | Ir.Footnote_def _ -> fail Unsafe_markdown in
  List.iter block blocks
let decode_literal_label label =
  let buffer=Buffer.create (String.length label) in
  let i=ref 0 in
  while !i<String.length label do
    let stop=ref (!i+1) in
    if label.[!i]='&' then
      while !stop<String.length label && !stop - !i <= 40 && label.[!stop]<>';' &&
        (match label.[!stop] with 'a'..'z'|'A'..'Z'|'0'..'9'|'#' -> true | _ -> false)
      do incr stop done;
    if label.[!i]='&' && !stop<String.length label && label.[!stop]=';' && !stop - !i<=40 then begin
      let token=String.sub label !i (!stop - !i+1) in
      let doc=Cmarkit.Doc.of_string ("X" ^ token) in
      let inline _ acc = function Cmarkit.Inline.Text (s,_) -> `Fold (acc ^ s) | _ -> `Default in
      let decoded=Cmarkit.Folder.fold_doc (Cmarkit.Folder.make ~inline ()) "" doc in
      if decoded="" || decoded.[0]<>'X' then fail Unsafe_markdown;
      Buffer.add_substring buffer decoded 1 (String.length decoded-1);
      i := !stop+1
    end else begin Buffer.add_char buffer label.[!i]; incr i end
  done;
  let value=Buffer.contents buffer in
  if String.exists (fun c -> Char.code c<0x20 || Char.code c=0x7f) value then fail Unsafe_markdown;
  value
let decode_labels blocks =
  let rec inlines xs = List.map (fun il ->
    let node=match il.Ir.node with
      | Ir.Wiki_link {target;alias=Some label} -> Ir.Wiki_link {target;alias=Some (decode_literal_label label)}
      | Ir.Emphasis xs -> Ir.Emphasis (inlines xs)
      | Ir.Strong xs -> Ir.Strong (inlines xs)
      | Ir.Strikethrough xs -> Ir.Strikethrough (inlines xs)
      | Ir.Highlight xs -> Ir.Highlight (inlines xs)
      | Ir.Link link -> Ir.Link {link with label=inlines link.label}
      | node -> node in
    {il with Ir.node}) xs
  and block b =
    let bnode=match b.Ir.bnode with
      | Ir.Paragraph xs -> Ir.Paragraph (inlines xs)
      | Ir.Blockquote bs -> Ir.Blockquote (List.map block bs)
      | Ir.List xs -> Ir.List {xs with items=List.map (fun i -> {i with Ir.item_blocks=List.map block i.Ir.item_blocks}) xs.items}
      | Ir.Table xs -> Ir.Table {xs with header=Option.map (List.map inlines) xs.header; rows=List.map (List.map inlines) xs.rows}
      | Ir.Callout xs -> Ir.Callout {xs with title=inlines xs.title; body=List.map block xs.body}
      | Ir.Footnotes xs -> Ir.Footnotes (List.map (fun (n,bs) -> n,List.map block bs) xs)
      | node -> node in
    {b with Ir.bnode} in
  List.map block blocks
let parse_chunk text =
  String.iteri (fun i c -> if c='\r' && (i+1=String.length text || text.[i+1]<>'\n')
    then fail Unsafe_markdown) text;
  let source = match Source.of_string ~path:"<public-chunk>" text with
    | Ok s -> s | Error _ -> fail Unsafe_markdown in
  guard_markdown source text;
  match Markdown.parse source ~masked_markdown:text Metadata.empty with
  | Error _ -> fail Unsafe_markdown
  | Ok (doc, warnings) ->
    if warnings <> [] then fail Unsafe_markdown;
    validate_blocks doc.Ir.blocks; {doc with Ir.blocks=decode_labels doc.Ir.blocks}
let fields = function `Assoc xs -> xs | _ -> fail Schema
let optional key json = Option.map string (List.assoc_opt key (fields json))
let synthetic_span = match Span.make ~path:"<public>" ~start_byte:0 ~end_byte:0 with
  | Ok s -> s | Error _ -> assert false
let located value = { Metadata.value; span=synthetic_span }
let literal_inlines value = [{ Ir.node=Ir.Text value; span=synthetic_span }]
let emit_metadata tree =
  let attrs key = List.map (fun a -> match string (member "kind" a) with
    | "literal" -> Metadata.Literal (located (string (member "value" a)))
    | "tree" -> Metadata.Tree (located (string (member "id" a)))
    | _ -> fail Schema) (list (member key tree)) in
  let property key value = (located key, located (literal_inlines value)) in
  let meta = fields (member "properties" tree) |> List.sort (fun (a,_) (b,_) -> String.compare a b)
    |> List.concat_map (fun (k,vs) -> List.map (fun v -> property k (native_property k (string v))) (list vs)) in
  let citations = List.map (fun s -> property "author" (string s)) (list (member "citationAuthors" tree)) in
  let year = match optional "publicationYear" tree with None -> [] | Some s -> [property "publication-year" s] in
  let metadata = { Metadata.date=None; taxon=Option.map located (optional "taxon" tree);
    authors=attrs "authors"; contributors=attrs "contributors"; tags=[]; meta=meta @ citations @ year } in
  let dates = List.map (fun s -> "\\date{" ^ string s ^ "}\n") (list (member "dates" tree)) in
  String.concat "" dates ^ Forester_6.emit_metadata_fragment metadata
let inspect_references target blocks =
  let rec inlines xs = List.iter (fun il -> match il.Ir.node with
    | Ir.Wiki_link {target=id; _} -> target id
    | Ir.Wiki_embed id -> target id
    | Ir.Link {label; destination; _} ->
      if not (starts "http://" destination || starts "https://" destination || starts "mailto:" destination)
      then target destination;
      inlines label
    | Ir.Image {alt; _} -> inlines alt
    | Ir.Emphasis xs | Ir.Strong xs | Ir.Strikethrough xs | Ir.Highlight xs -> inlines xs
    | Ir.Text _ | Ir.Code _ | Ir.Math _ | Ir.Footnote_ref _ | Ir.Hard_break | Ir.Soft_break -> ()) xs
  and block b = match b.Ir.bnode with
    | Ir.Paragraph xs | Ir.Heading {title=xs; _} -> inlines xs
    | Ir.Blockquote bs | Ir.Footnote_def {body=bs; _} -> List.iter block bs
    | Ir.List {items; _} -> List.iter (fun i -> List.iter block i.Ir.item_blocks) items
    | Ir.Table {header; rows; _} ->
      Option.iter (List.iter inlines) header; List.iter (List.iter inlines) rows
    | Ir.Callout {title; body; _} -> inlines title; List.iter block body
    | Ir.Footnotes entries -> List.iter (fun (_,bs) -> List.iter block bs) entries
    | Ir.Block_embed id -> target id
    | Ir.Code_block _ | Ir.Card_link _ | Ir.Thematic_break | Ir.Subtree_directive _
    | Ir.Subtree_open _ | Ir.Subtree_close _ | Ir.Display_math _ -> () in
  List.iter block blocks
let validate_graph roots =
  let named = Hashtbl.create 32 in
  let vertices = ref [] in
  let count = ref 0 in
  let rec index parent tree =
    let vertex = !count in incr count;
    Option.iter (fun id -> Hashtbl.add named id vertex) (optional "id" tree);
    vertices := (vertex, parent, tree) :: !vertices;
    List.iter (fun n -> if string (member "kind" n) = "subtree"
      then index (Some vertex) (member "tree" n)) (list (member "content" tree)) in
  List.iter (index None) roots;
  let outgoing = Array.make !count [] and incoming = Array.make !count 0 in
  let target id =
    if not (valid_id id) then fail Invalid_id;
    match Hashtbl.find_opt named id with Some v -> v | None -> fail Missing_target in
  let edge from into = outgoing.(from) <- into::outgoing.(from); incoming.(into) <- incoming.(into)+1 in
  List.iter (fun (vertex,parent,tree) ->
    Option.iter (fun p -> edge p vertex) parent;
    List.iter (fun key -> List.iter (fun attr ->
      if string (member "kind" attr) = "tree" then ignore (target (string (member "id" attr))))
      (list (member key tree))) ["authors";"contributors"];
    List.iter (fun node -> match string (member "kind" node) with
      | "transclude" -> edge vertex (target (string (member "id" node)))
      | "markdown" ->
        let doc = parse_chunk (string (member "text" node)) in
        inspect_references (fun id -> ignore (target id)) doc.Ir.blocks
      | _ -> ()) (list (member "content" tree))) !vertices;
  let queue = Queue.create () in
  Array.iteri (fun v n -> if n=0 then Queue.add v queue) incoming;
  let visited = ref 0 in
  while not (Queue.is_empty queue) do
    let v = Queue.take queue in incr visited;
    List.iter (fun w -> incoming.(w) <- incoming.(w)-1;
      if incoming.(w)=0 then Queue.add w queue) outgoing.(v)
  done;
  if !visited <> !count then fail Cycle
let compile_forest roots = protect (fun () ->
  validate_graph roots;
  let rec emit_tree tree =
    let header = "\\title{" ^ Forester_6.escape_literal (string (member "title" tree)) ^ "}\n" in
    header ^ emit_metadata tree ^ String.concat "" (List.map emit_node (list (member "content" tree)))
  and emit_node node = match string (member "kind" node) with
    | "markdown" ->
      let doc = parse_chunk (string (member "text" node)) in
      (match Forester_6.emit_blocks_fragment ~resolution:Resolution.empty doc.Ir.blocks with
       | Ok (s, _) -> s | Error _ -> fail Unsafe_markdown)
    | "subtree" ->
      let tree = member "tree" node in
      let address = match optional "id" tree with None -> "" | Some id -> "[" ^ id ^ "]" in
      "\\subtree" ^ address ^ "{\n" ^ emit_tree tree ^ "}\n"
    | "transclude" ->
      let id = string (member "id" node) in
      let header = boolean (member "header" node) and toc = boolean (member "toc" node) in
      let transclusion = "\\transclude{" ^ id ^ "}" in
      if header && toc then transclusion ^ "\n"
      else "\\scope{\\put\\transclude/heading{" ^ string_of_bool header ^
        "}\\put\\transclude/toc{" ^ string_of_bool toc ^ "}" ^ transclusion ^ "}\n"
    | _ -> fail Schema in
  List.sort (fun a b -> String.compare (string (member "id" a)) (string (member "id" b))) roots
  |> List.map (fun root -> (string (member "id" root) ^ ".tree", emit_tree root)))

let lstat_opt path =
  try Some (Unix.lstat path) with Unix.Unix_error (Unix.ENOENT,_,_) -> None
let safe_namespace error path =
  if path="" || String.exists (fun c -> Char.code c<0x20 || Char.code c=0x7f) path then fail error;
  let absolute = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
  let components = String.split_on_char '/' absolute |> List.filter (fun s -> s<>"" && s<>".") in
  if List.mem ".." components then fail error;
  let rec check base = function
    | [] -> base
    | name::rest ->
      let path=Filename.concat base name in
      (match lstat_opt path with
       | Some stat when stat.Unix.st_kind=Unix.S_LNK -> fail error
       | Some stat when rest<>[] && stat.Unix.st_kind<>Unix.S_DIR -> fail error
       | _ -> ());
      check path rest in
  check "/" components
let rec mkdir_parents path =
  match lstat_opt path with
  | Some stat when stat.Unix.st_kind=Unix.S_DIR -> ()
  | Some _ -> fail Unsafe_output
  | None -> mkdir_parents (Filename.dirname path); Unix.mkdir path 0o700
let load_file input =
  try
    let input = safe_namespace Io input in
    let stat = Unix.lstat input in
    if stat.Unix.st_kind <> Unix.S_REG then Error Io
    else if stat.Unix.st_size > max_json_bytes then Error Limit
    else
      let channel = open_in_bin input in
      Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
        let size = in_channel_length channel in
        if size > max_json_bytes then Error Limit
        else of_string (really_input_string channel size))
  with Reject e -> Error e
     | Unix.Unix_error _ | Sys_error _ | End_of_file -> Error Io
let write_forest ~out_dir forest =
  match compile_forest forest with
  | Error e -> Error e
  | Ok files ->
    try
      let out_dir = safe_namespace Unsafe_output out_dir in
      (match lstat_opt out_dir with
       | Some stat when stat.Unix.st_kind=Unix.S_DIR && Sys.readdir out_dir=[||] -> ()
       | Some _ -> fail Unsafe_output
       | None -> ());
      mkdir_parents out_dir;
      List.iter (fun (name,text) ->
        let channel = open_out_gen [Open_wronly;Open_creat;Open_excl;Open_binary] 0o600
          (Filename.concat out_dir name) in
        Fun.protect ~finally:(fun () -> close_out_noerr channel)
          (fun () -> output_string channel text; close_out channel)) files;
      Ok (List.length files)
    with Reject e -> Error e | Unix.Unix_error _ | Sys_error _ -> Error Unsafe_output
let convert_file ~input ~out_dir =
  match load_file input with Error e -> Error e | Ok forest -> write_forest ~out_dir forest
