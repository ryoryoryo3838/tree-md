type issue = { pointer : string; code : string; message : string }

(* ── the profile ──

   mdbase v0.3 §06 "Required Support" lists exactly these. Annotations carry no
   assertion and are accepted and ignored; `$schema` and `$id` are metadata. *)
let assertion_keywords =
  [ "type"; "required"; "properties"; "additionalProperties"; "items"; "enum";
    "const"; "oneOf"; "anyOf"; "allOf"; "if"; "then"; "else"; "minimum";
    "maximum"; "exclusiveMinimum"; "exclusiveMaximum"; "multipleOf";
    "minLength"; "maxLength"; "pattern"; "minItems"; "maxItems"; "uniqueItems";
    "$defs"; "$ref"; "format" ]

let annotation_keywords =
  [ "title"; "description"; "default"; "examples"; "deprecated"; "readOnly";
    "writeOnly"; "$schema"; "$id"; "$comment" ]

let supported_keywords = assertion_keywords @ annotation_keywords

(* ── compiled form ── *)

type node = {
  types : string list option;
  required : string list;
  properties : (string * node) list;
  (* [None] when the keyword is absent, which JSON Schema reads as true. *)
  additional : additional option;
  items : node option;
  enum : Yojson.Safe.t list option;
  const : Yojson.Safe.t option;
  one_of : node list option;
  any_of : node list option;
  all_of : node list option;
  if_ : node option;
  then_ : node option;
  else_ : node option;
  minimum : float option;
  maximum : float option;
  exclusive_minimum : float option;
  exclusive_maximum : float option;
  multiple_of : float option;
  min_length : int option;
  max_length : int option;
  pattern : (string * Re.re) option;
  min_items : int option;
  max_items : int option;
  unique_items : bool;
  format : string option;
  (* A local `$ref`, resolved lazily so that `$defs` may be mutually
     recursive without the compiler looping. *)
  ref_ : string option;
}

and additional = Allowed | Forbidden | Schema of node

type t = { root : node; defs : (string * node) list }

let empty_node = {
  types = None; required = []; properties = []; additional = None;
  items = None; enum = None; const = None; one_of = None; any_of = None;
  all_of = None; if_ = None; then_ = None; else_ = None; minimum = None;
  maximum = None; exclusive_minimum = None; exclusive_maximum = None;
  multiple_of = None; min_length = None; max_length = None; pattern = None;
  min_items = None; max_items = None; unique_items = false; format = None;
  ref_ = None;
}

(* ── compilation ── *)

let ( let* ) = Result.bind

let as_string context = function
  | `String s -> Ok s
  | _ -> Error (context ^ " must be a string")

let as_int context = function
  | `Int n -> Ok n
  | _ -> Error (context ^ " must be an integer")

let as_number context = function
  | `Int n -> Ok (float_of_int n)
  | `Float f -> Ok f
  | `Intlit s -> (
    match float_of_string_opt s with
    | Some f -> Ok f
    | None -> Error (context ^ " must be a number"))
  | _ -> Error (context ^ " must be a number")

let as_list context = function
  | `List items -> Ok items
  | _ -> Error (context ^ " must be an array")

let rec map_result f = function
  | [] -> Ok []
  | x :: rest ->
    let* y = f x in
    let* ys = map_result f rest in
    Ok (y :: ys)

(* mdbase v0.3 §07 fixes the regular-expression subset: Unicode-aware, without
   backreferences or look-around. Both are refused here rather than silently
   accepted with different meaning. *)
let compile_pattern source =
  let has_unsupported =
    let len = String.length source in
    let rec loop i =
      if i >= len then false
      else if source.[i] = '\\' then
        if i + 1 < len && source.[i + 1] >= '1' && source.[i + 1] <= '9' then true
        else loop (i + 2)
      else if
        source.[i] = '('
        && i + 2 < len
        && source.[i + 1] = '?'
        && (source.[i + 2] = '=' || source.[i + 2] = '!' || source.[i + 2] = '<')
        && not (i + 3 < len && source.[i + 2] = '<' && source.[i + 3] = '>')
      then true
      else loop (i + 1)
    in
    loop 0
  in
  if has_unsupported then
    Error
      ("pattern \"" ^ source
       ^ "\" uses a backreference or look-around, which the mdbase regular \
          expression subset does not include")
  else
    match Re.Pcre.re source with
    | regex -> Ok (source, Re.compile regex)
    | exception _ -> Error ("pattern \"" ^ source ^ "\" is not a valid regular expression")

let rec compile_node ~path (json : Yojson.Safe.t) =
  match json with
  (* A boolean schema: `true` allows anything, `false` allows nothing. The
     latter is expressed as an impossible enum. *)
  | `Bool true -> Ok empty_node
  | `Bool false -> Ok { empty_node with enum = Some [] }
  | `Assoc fields ->
    let unknown =
      List.filter (fun (key, _) -> not (List.mem key supported_keywords)) fields
    in
    (match unknown with
     | (key, _) :: _ ->
       Error
         (path ^ ": \"" ^ key
          ^ "\" is outside the JSON Schema profile mdbase v0.3 requires; \
             supported keywords are " ^ String.concat ", " assertion_keywords)
     | [] ->
       let find key = List.assoc_opt key fields in
       let at key = path ^ "/" ^ key in
       let* types =
         match find "type" with
         | None -> Ok None
         | Some (`String s) -> Ok (Some [ s ])
         | Some (`List items) ->
           let* names = map_result (as_string (at "type")) items in
           Ok (Some names)
         | Some _ -> Error (at "type" ^ " must be a string or an array of strings")
       in
       let* required =
         match find "required" with
         | None -> Ok []
         | Some value ->
           let* items = as_list (at "required") value in
           map_result (as_string (at "required")) items
       in
       let* properties =
         match find "properties" with
         | None -> Ok []
         | Some (`Assoc entries) ->
           map_result
             (fun (name, schema) ->
               let* node = compile_node ~path:(at ("properties/" ^ name)) schema in
               Ok (name, node))
             entries
         | Some _ -> Error (at "properties" ^ " must be an object")
       in
       let* additional =
         match find "additionalProperties" with
         | None -> Ok None
         | Some (`Bool true) -> Ok (Some Allowed)
         | Some (`Bool false) -> Ok (Some Forbidden)
         | Some schema ->
           let* node = compile_node ~path:(at "additionalProperties") schema in
           Ok (Some (Schema node))
       in
       let* items =
         match find "items" with
         | None -> Ok None
         | Some schema ->
           let* node = compile_node ~path:(at "items") schema in
           Ok (Some node)
       in
       let* enum =
         match find "enum" with
         | None -> Ok None
         | Some value ->
           let* items = as_list (at "enum") value in
           Ok (Some items)
       in
       let const = find "const" in
       let compile_branches key =
         match find key with
         | None -> Ok None
         | Some value ->
           let* items = as_list (at key) value in
           let* nodes =
             map_result (fun schema -> compile_node ~path:(at key) schema) items
           in
           Ok (Some nodes)
       in
       let* one_of = compile_branches "oneOf" in
       let* any_of = compile_branches "anyOf" in
       let* all_of = compile_branches "allOf" in
       let compile_optional key =
         match find key with
         | None -> Ok None
         | Some schema ->
           let* node = compile_node ~path:(at key) schema in
           Ok (Some node)
       in
       let* if_ = compile_optional "if" in
       let* then_ = compile_optional "then" in
       let* else_ = compile_optional "else" in
       let number key =
         match find key with
         | None -> Ok None
         | Some value ->
           let* n = as_number (at key) value in
           Ok (Some n)
       in
       let* minimum = number "minimum" in
       let* maximum = number "maximum" in
       let* exclusive_minimum = number "exclusiveMinimum" in
       let* exclusive_maximum = number "exclusiveMaximum" in
       let* multiple_of = number "multipleOf" in
       let integer key =
         match find key with
         | None -> Ok None
         | Some value ->
           let* n = as_int (at key) value in
           Ok (Some n)
       in
       let* min_length = integer "minLength" in
       let* max_length = integer "maxLength" in
       let* min_items = integer "minItems" in
       let* max_items = integer "maxItems" in
       let* pattern =
         match find "pattern" with
         | None -> Ok None
         | Some value ->
           let* source = as_string (at "pattern") value in
           let* compiled = compile_pattern source in
           Ok (Some compiled)
       in
       let unique_items = find "uniqueItems" = Some (`Bool true) in
       let* format =
         match find "format" with
         | None -> Ok None
         | Some value ->
           let* name = as_string (at "format") value in
           Ok (Some name)
       in
       let* ref_ =
         match find "$ref" with
         | None -> Ok None
         | Some value ->
           let* target = as_string (at "$ref") value in
           let prefix = "#/$defs/" in
           let n = String.length prefix in
           if String.length target > n && String.sub target 0 n = prefix then
             Ok (Some (String.sub target n (String.length target - n)))
           else
             Error
               (at "$ref" ^ ": only a fragment-only reference into $defs is \
                 supported, such as \"#/$defs/name\"")
       in
       Ok
         { types; required; properties; additional; items; enum; const; one_of;
           any_of; all_of; if_; then_; else_; minimum; maximum;
           exclusive_minimum; exclusive_maximum; multiple_of; min_length;
           max_length; pattern; min_items; max_items; unique_items; format;
           ref_ })
  | _ -> Error (path ^ " must be an object or a boolean")

let compile json =
  let* defs =
    match json with
    | `Assoc fields -> (
      match List.assoc_opt "$defs" fields with
      | None -> Ok []
      | Some (`Assoc entries) ->
        map_result
          (fun (name, schema) ->
            let* node = compile_node ~path:("#/$defs/" ^ name) schema in
            Ok (name, node))
          entries
      | Some _ -> Error "$defs must be an object")
    | _ -> Ok []
  in
  let* root = compile_node ~path:"#" json in
  Ok { root; defs }

(* ── validation ── *)

let utf8_length s =
  let n = ref 0 in
  String.iter (fun c -> if Char.code c land 0xC0 <> 0x80 then incr n) s;
  !n

let type_name : Yojson.Safe.t -> string = function
  | `Null -> "null"
  | `Bool _ -> "boolean"
  | `Int _ | `Intlit _ -> "integer"
  | `Float _ -> "number"
  | `String _ -> "string"
  | `List _ -> "array"
  | `Assoc _ -> "object"

let matches_type value name =
  match (name, value) with
  | "null", `Null -> true
  | "boolean", `Bool _ -> true
  | "integer", (`Int _ | `Intlit _) -> true
  | "integer", `Float f -> Float.is_integer f
  | "number", (`Int _ | `Intlit _ | `Float _) -> true
  | "string", `String _ -> true
  | "array", `List _ -> true
  | "object", `Assoc _ -> true
  | _ -> false

let number_of : Yojson.Safe.t -> float option = function
  | `Int n -> Some (float_of_int n)
  | `Float f -> Some f
  | `Intlit s -> float_of_string_opt s
  | _ -> None

(* RFC 3339, as JSON Schema references it. Dates are checked for real: 2026-02-30
   is not a date. *)
let is_leap year = (year mod 4 = 0 && year mod 100 <> 0) || year mod 400 = 0

let days_in_month year month =
  match month with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if is_leap year then 29 else 28
  | _ -> 0

let digits s from count =
  String.length s >= from + count
  && (let rec loop i =
        i >= from + count || (s.[i] >= '0' && s.[i] <= '9' && loop (i + 1))
      in
      loop from)

let int_at s from count = int_of_string (String.sub s from count)

let valid_full_date s =
  String.length s = 10
  && digits s 0 4 && s.[4] = '-' && digits s 5 2 && s.[7] = '-' && digits s 8 2
  && (let year = int_at s 0 4 and month = int_at s 5 2 and day = int_at s 8 2 in
      month >= 1 && month <= 12 && day >= 1 && day <= days_in_month year month)

let valid_partial_time s =
  String.length s = 8
  && digits s 0 2 && s.[2] = ':' && digits s 3 2 && s.[5] = ':' && digits s 6 2
  && int_at s 0 2 <= 23 && int_at s 3 2 <= 59 && int_at s 6 2 <= 60

let valid_offset s =
  s = "Z"
  || (String.length s = 6
      && (s.[0] = '+' || s.[0] = '-')
      && digits s 1 2 && s.[3] = ':' && digits s 4 2
      && int_at s 1 2 <= 23 && int_at s 4 2 <= 59)

let valid_time s =
  (String.length s = 9 && valid_partial_time (String.sub s 0 8) && s.[8] = 'Z')
  || (String.length s = 14
      && valid_partial_time (String.sub s 0 8)
      && valid_offset (String.sub s 8 6))
  || valid_partial_time s

let valid_date_time s =
  String.length s >= 20
  && valid_full_date (String.sub s 0 10)
  && s.[10] = 'T'
  && valid_partial_time (String.sub s 11 8)
  && valid_offset (String.sub s 19 (String.length s - 19))

let escape_pointer_token token =
  let buf = Buffer.create (String.length token + 4) in
  String.iter
    (fun c ->
      match c with
      | '~' -> Buffer.add_string buf "~0"
      | '/' -> Buffer.add_string buf "~1"
      | c -> Buffer.add_char buf c)
    token;
  Buffer.contents buf

let validate schema value =
  let issues = ref [] in
  let add pointer code message =
    issues := { pointer; code; message } :: !issues
  in
  let resolve node =
    match node.ref_ with
    | None -> node
    | Some name -> (
      match List.assoc_opt name schema.defs with
      | Some target -> target
      | None -> node)
  in
  (* A branch is checked in isolation so that oneOf/anyOf can count successes
     without reporting the failures of branches that were never meant. *)
  let rec branch_ok node value =
    let saved = !issues in
    issues := [];
    check "" node value;
    let failed = !issues <> [] in
    issues := saved;
    not failed

  and check pointer node value =
    let node = resolve node in
    (match node.types with
     | Some names when not (List.exists (matches_type value) names) ->
       add pointer "schema_type"
         ("expected " ^ String.concat " or " names ^ ", found " ^ type_name value)
     | _ -> ());
    (match node.const with
     | Some expected when expected <> value ->
       add pointer "schema_const"
         ("must be " ^ Yojson.Safe.to_string expected)
     | _ -> ());
    (match node.enum with
     | Some allowed when not (List.mem value allowed) ->
       add pointer "schema_enum"
         ("must be one of "
          ^ String.concat ", " (List.map Yojson.Safe.to_string allowed))
     | _ -> ());
    (match value with
     | `String s ->
       (match node.min_length with
        | Some n when utf8_length s < n ->
          add pointer "schema_min_length"
            ("must be at least " ^ string_of_int n ^ " characters")
        | _ -> ());
       (match node.max_length with
        | Some n when utf8_length s > n ->
          add pointer "schema_max_length"
            ("must be at most " ^ string_of_int n ^ " characters")
        | _ -> ());
       (match node.pattern with
        | Some (source, regex) when not (Re.execp regex s) ->
          add pointer "schema_pattern" ("must match " ^ source)
        | _ -> ());
       (match node.format with
        | Some "date" when not (valid_full_date s) ->
          add pointer "format_invalid" "must be an RFC 3339 full-date"
        | Some "date-time" when not (valid_date_time s) ->
          add pointer "format_invalid" "must be an RFC 3339 date-time"
        | Some "time" when not (valid_time s) ->
          add pointer "format_invalid" "must be an RFC 3339 time"
        | _ -> ())
     | _ -> ());
    (match number_of value with
     | Some n ->
       (match node.minimum with
        | Some limit when n < limit ->
          add pointer "schema_minimum" ("must be at least " ^ string_of_float limit)
        | _ -> ());
       (match node.maximum with
        | Some limit when n > limit ->
          add pointer "schema_maximum" ("must be at most " ^ string_of_float limit)
        | _ -> ());
       (match node.exclusive_minimum with
        | Some limit when n <= limit ->
          add pointer "schema_exclusive_minimum"
            ("must be greater than " ^ string_of_float limit)
        | _ -> ());
       (match node.exclusive_maximum with
        | Some limit when n >= limit ->
          add pointer "schema_exclusive_maximum"
            ("must be less than " ^ string_of_float limit)
        | _ -> ());
       (match node.multiple_of with
        | Some divisor when divisor > 0. && Float.rem n divisor <> 0. ->
          add pointer "schema_multiple_of"
            ("must be a multiple of " ^ string_of_float divisor)
        | _ -> ())
     | None -> ());
    (match value with
     | `List items ->
       (match node.min_items with
        | Some n when List.length items < n ->
          add pointer "schema_min_items"
            ("must have at least " ^ string_of_int n ^ " items")
        | _ -> ());
       (match node.max_items with
        | Some n when List.length items > n ->
          add pointer "schema_max_items"
            ("must have at most " ^ string_of_int n ^ " items")
        | _ -> ());
       if node.unique_items then begin
         let rec has_duplicate = function
           | [] -> false
           | x :: rest -> List.mem x rest || has_duplicate rest
         in
         if has_duplicate items then
           add pointer "schema_unique_items" "items must be unique"
       end;
       (match node.items with
        | Some item_schema ->
          List.iteri
            (fun index item ->
              check (pointer ^ "/" ^ string_of_int index) item_schema item)
            items
        | None -> ())
     | _ -> ());
    (match value with
     | `Assoc entries ->
       List.iter
         (fun name ->
           if not (List.mem_assoc name entries) then
             add pointer "schema_required" ("\"" ^ name ^ "\" is required"))
         node.required;
       List.iter
         (fun (name, entry) ->
           let child = pointer ^ "/" ^ escape_pointer_token name in
           match List.assoc_opt name node.properties with
           | Some property -> check child property entry
           | None -> (
             match node.additional with
             | None | Some Allowed -> ()
             | Some Forbidden ->
               add child "schema_additional_properties"
                 ("\"" ^ name ^ "\" is not a property this type declares")
             | Some (Schema additional) -> check child additional entry))
         entries
     | _ -> ());
    (match node.all_of with
     | Some branches -> List.iter (fun b -> check pointer b value) branches
     | None -> ());
    (match node.any_of with
     | Some branches when not (List.exists (fun b -> branch_ok b value) branches) ->
       add pointer "schema_any_of" "matches none of the permitted shapes"
     | _ -> ());
    (match node.one_of with
     | Some branches -> (
       let matched = List.length (List.filter (fun b -> branch_ok b value) branches) in
       match matched with
       | 1 -> ()
       | 0 -> add pointer "schema_one_of" "matches none of the permitted shapes"
       | n ->
         add pointer "schema_one_of"
           ("matches " ^ string_of_int n
            ^ " of the permitted shapes; exactly one must match"))
     | None -> ());
    (match node.if_ with
     | None -> ()
     | Some condition ->
       if branch_ok condition value then
         match node.then_ with Some t -> check pointer t value | None -> ()
       else match node.else_ with Some e -> check pointer e value | None -> ())
  in
  check "" schema.root value;
  List.rev !issues
