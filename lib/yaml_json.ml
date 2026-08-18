type t = { value : value; text : string option; span : Span.t }

and value =
  | Null
  | Bool of bool
  | Int of int
  | Float of float
  | String of string
  | List of t list
  | Assoc of field list

and field = { name : string; name_span : Span.t; value : t }

let is_digits s from =
  let len = String.length s in
  len > from
  && (let rec loop i =
        i >= len || (s.[i] >= '0' && s.[i] <= '9' && loop (i + 1))
      in
      loop from)

let strip_sign s =
  if s <> "" && (s.[0] = '-' || s.[0] = '+') then
    (String.sub s 1 (String.length s - 1), s.[0] = '-')
  else (s, false)

let is_hex_digits s =
  s <> ""
  && String.for_all
       (fun c ->
         (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))
       s

let is_octal_digits s = s <> "" && String.for_all (fun c -> c >= '0' && c <= '7') s

(* YAML 1.2 core schema, minus the productions that have no JSON counterpart.
   [Error] is what of_plain_scalar turns into a diagnostic. *)
let core_schema s =
  match s with
  | "" | "~" | "null" | "Null" | "NULL" -> Ok Null
  | "true" | "True" | "TRUE" -> Ok (Bool true)
  | "false" | "False" | "FALSE" -> Ok (Bool false)
  | ".nan" | ".NaN" | ".NAN" ->
    Error "NaN has no JSON counterpart; quote it to keep it a string"
  | _ ->
    let body, _negative = strip_sign s in
    if body = ".inf" || body = ".Inf" || body = ".INF" then
      Error "an infinity has no JSON counterpart; quote it to keep it a string"
    else if is_digits s 0 || (body <> "" && is_digits body 0 && s <> body) then
      match int_of_string_opt s with
      | Some n -> Ok (Int n)
      | None -> (
        (* A run of digits too long for an int is still a number. *)
        match float_of_string_opt s with
        | Some f -> Ok (Float f)
        | None -> Ok (String s))
    else if
      String.length body > 2 && body.[0] = '0' && (body.[1] = 'x' || body.[1] = 'X')
      && is_hex_digits (String.sub body 2 (String.length body - 2))
    then
      match int_of_string_opt s with
      | Some n -> Ok (Int n)
      | None -> Ok (String s)
    else if
      String.length body > 2 && body.[0] = '0' && (body.[1] = 'o' || body.[1] = 'O')
      && is_octal_digits (String.sub body 2 (String.length body - 2))
    then
      match int_of_string_opt s with
      | Some n -> Ok (Int n)
      | None -> Ok (String s)
    else
      (* A float only when the whole scalar is one; float_of_string_opt would
         otherwise accept spellings YAML does not, such as "0x1p3" or "nan". *)
      let looks_numeric =
        body <> ""
        && String.for_all
             (fun c ->
               (c >= '0' && c <= '9') || c = '.' || c = 'e' || c = 'E'
               || c = '+' || c = '-')
             body
        && String.exists (fun c -> c >= '0' && c <= '9') body
      in
      if looks_numeric then
        match float_of_string_opt s with
        | Some f -> Ok (Float f)
        | None -> Ok (String s)
      else Ok (String s)

let of_plain_scalar s = core_schema s

let resolve_plain s = match core_schema s with Ok v -> v | Error _ -> String s

let rec to_yojson node : Yojson.Safe.t =
  match node.value with
  | Null -> `Null
  | Bool b -> `Bool b
  | Int n -> `Int n
  | Float f -> `Float f
  | String s -> `String s
  | List items -> `List (List.map to_yojson items)
  | Assoc entries ->
    `Assoc (List.map (fun f -> (f.name, to_yojson f.value)) entries)

let fields node = match node.value with Assoc entries -> entries | _ -> []

let field node name =
  List.find_map
    (fun f -> if String.equal f.name name then Some f.value else None)
    (fields node)

let keys node = List.map (fun f -> (f.name, f.name_span)) (fields node)

let as_text node = node.text

let rec of_yojson ~span (json : Yojson.Safe.t) =
  let node value text = { value; text; span } in
  match json with
  | `Null -> node Null None
  | `Bool b -> node (Bool b) (Some (string_of_bool b))
  | `Int n -> node (Int n) (Some (string_of_int n))
  | `Intlit s -> node (String s) (Some s)
  | `Float f -> node (Float f) (Some (string_of_float f))
  | `String s -> node (String s) (Some s)
  | `List items -> node (List (List.map (of_yojson ~span) items)) None
  | `Assoc entries ->
    node
      (Assoc
         (List.map
            (fun (name, value) ->
              { name; name_span = span; value = of_yojson ~span value })
            entries))
      None

(* RFC 6901: `~1` is `/` and `~0` is `~`, decoded in that order. *)
let unescape_token token =
  let buf = Buffer.create (String.length token) in
  let n = String.length token in
  let i = ref 0 in
  while !i < n do
    if token.[!i] = '~' && !i + 1 < n then begin
      (match token.[!i + 1] with
       | '1' -> Buffer.add_char buf '/'
       | '0' -> Buffer.add_char buf '~'
       | c -> Buffer.add_char buf '~'; Buffer.add_char buf c);
      i := !i + 2
    end
    else begin Buffer.add_char buf token.[!i]; incr i end
  done;
  Buffer.contents buf

let locate node pointer =
  if pointer = "" then Some node.span
  else
    let tokens =
      String.split_on_char '/' (String.sub pointer 1 (String.length pointer - 1))
      |> List.map unescape_token
    in
    let rec walk node = function
      | [] -> Some node.span
      | token :: rest -> (
        match node.value with
        | Assoc entries -> (
          match
            List.find_opt (fun f -> String.equal f.name token) entries
          with
          | Some f -> walk f.value rest
          | None -> Some node.span)
        | List items -> (
          match int_of_string_opt token with
          | Some index -> (
            match List.nth_opt items index with
            | Some item -> walk item rest
            | None -> Some node.span)
          | None -> Some node.span)
        | _ -> Some node.span)
    in
    walk node tokens

let with_defaults node defaults =
  match node.value with
  | Assoc entries ->
    let missing =
      List.filter
        (fun (name, _) ->
          not (List.exists (fun f -> String.equal f.name name) entries))
        defaults
    in
    let added =
      List.map
        (fun (name, value) ->
          { name; name_span = node.span; value = of_yojson ~span:node.span value })
        missing
    in
    { node with value = Assoc (entries @ added) }
  | _ -> node

let describe = function
  | Null -> "null"
  | Bool _ -> "a boolean"
  | Int _ | Float _ -> "a number"
  | String _ -> "a string"
  | List _ -> "a list"
  | Assoc _ -> "a mapping"
