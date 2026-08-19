type forest = {
  path : string;
  directory : string;
  tree_roots : (Path_safe.relative * string) list;
  asset_roots : (Path_safe.relative * string) list;
}

type id_scheme = Sequential | Random

(* Who fulfils a request for an address. Deciding what the address is stays
   here whatever the answer, so that a forest has one scheme rather than one
   per tool; only the writing moves. *)
type id_minter = By_build | Off

type id_policy = {
  alphabet : string;
  width : int;
  scheme : id_scheme;
  prefix : string;
  mint : id_minter;
}

(* Forester's own convention, from its documentation: "NNNN is a four-digit
   base-36 number … so that you are not tempted to rename it".

   Random rather than sequential, because addresses are minted from more than
   one place — this compiler, and the Obsidian plugin, possibly on a phone with
   no sight of the forest. Two sequential minters would hand out the same next
   number; two random ones collide only by chance, and each checks what is
   already taken before it writes. A single-writer forest can say
   `scheme = "sequential"` and get dense, readable addresses back. *)
let default_id_policy = {
  alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  width = 4;
  scheme = Random;
  prefix = "";
  mint = By_build;
}

type t = {
  path : string;
  directory : string;
  forest : forest;
  source_roots : (Path_safe.relative * string) list;
  output_root : Path_safe.relative * string;
  target : string;
  id : id_policy;
  publish_from : string list;
}

let ( let* ) = Result.bind

let diagnostic path message =
  Error [Diagnostic.make TM401 (Span.Path path) (path ^ ": " ^ message)]

let read_file path =
  try
    let channel = open_in_bin path in
    let contents =
      Fun.protect
        ~finally:(fun () -> close_in_noerr channel)
        (fun () -> really_input_string channel (in_channel_length channel))
    in
    Ok contents
  with
  | Sys_error message -> diagnostic path ("cannot read file: " ^ message)

let parse path contents =
  match Otoml.Parser.from_string_result contents with
  | Ok value -> Ok value
  | Error message -> diagnostic path message

let table_fields path value =
  match value with
  | Otoml.TomlTable fields | Otoml.TomlInlineTable fields -> Ok fields
  | _ -> diagnostic path "top-level value must be a table"

let find_field name fields = List.assoc_opt name fields

let unknown_field allowed fields =
  List.find_opt (fun (name, _) -> not (List.mem name allowed)) fields

let require_field path name fields =
  match find_field name fields with
  | Some value -> Ok value
  | None -> diagnostic path ("missing field " ^ name)

let check_closed path allowed fields =
  match unknown_field allowed fields with
  | Some (name, _) -> diagnostic path ("unknown field " ^ name)
  | None -> Ok ()

let string_field path name fields =
  let* value = require_field path name fields in
  match value with
  | Otoml.TomlString value -> Ok value
  | _ -> diagnostic path (name ^ " must be a string")

let relative_field path name value =
  match Path_safe.relative value with
  | Ok path -> Ok path
  | Error message -> diagnostic path (name ^ ": " ^ message)

let relative_list path name value =
  let rec decode = function
    | [] -> Ok []
    | Otoml.TomlString value :: rest ->
      let* value = relative_field path name value in
      let* rest = decode rest in
      Ok (value :: rest)
    | _ -> diagnostic path (name ^ " must contain only strings")
  in
  match value with
  | Otoml.TomlArray values -> decode values
  | _ -> diagnostic path (name ^ " must be an array of strings")

let relative_list_field path name fields =
  let* value = require_field path name fields in
  relative_list path name value

let duplicate_relative paths =
  let rec loop seen = function
    | [] -> false
    | path :: rest ->
      let value = Path_safe.to_string path in
      if List.mem value seen then true else loop (value :: seen) rest
  in
  loop [] paths

let resolved_pairs ~base paths =
  List.map (fun path -> (path, Path_safe.resolve ~base path)) paths

let overlaps first second =
  Path_safe.is_within ~root:first second || Path_safe.is_within ~root:second first

let check_source_output_overlap path source_roots output_path =
  if List.exists (fun (_, source) -> overlaps source output_path) source_roots then
    diagnostic path "output overlaps a source root"
  else Ok ()

let check_output_tree path output_path tree_roots =
  if List.exists (fun (_, tree) -> tree = output_path) tree_roots then Ok ()
  else diagnostic path "output root is absent from forest.trees"

let decode_forest forest_path value =
  let* fields = table_fields forest_path value in
  let* forest_value = require_field forest_path "forest" fields in
  let* forest_fields = table_fields forest_path forest_value in
  (* forest.toml is user-owned: unknown keys (e.g. url) are allowed; only
     trees/assets are validated for type and lexical path safety. *)
  let* trees =
    match find_field "trees" forest_fields with
    | Some value -> relative_list forest_path "forest.trees" value
    | None -> diagnostic forest_path "missing field forest.trees"
  in
  let* assets =
    match find_field "assets" forest_fields with
    | Some value -> relative_list forest_path "forest.assets" value
    | None -> diagnostic forest_path "missing field forest.assets"
  in
  if duplicate_relative trees then diagnostic forest_path "duplicate forest tree root"
  else if duplicate_relative assets then diagnostic forest_path "duplicate forest asset root"
  else
    let directory = Filename.dirname forest_path in
    Ok {
      path = forest_path;
      directory;
      tree_roots = resolved_pairs ~base:directory trees;
      asset_roots = resolved_pairs ~base:directory assets;
    }

let load_forest forest_path =
  let* contents = read_file forest_path in
  let* value = parse forest_path contents in
  decode_forest forest_path value

(* Every character an address is built from has to be legal in one, and the
   first has to be alphanumeric, because zero-padding puts it there. *)
let id_char c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  || c = '.' || c = '_' || c = '-'

let alnum c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')

let has_duplicate_chars s =
  let seen = Array.make 256 false in
  let rec loop i =
    if i >= String.length s then false
    else
      let c = Char.code s.[i] in
      if seen.(c) then true else (seen.(c) <- true; loop (i + 1))
  in
  loop 0

(* `[publish].from` selects which trees a build starts from. Everything else
   under the source roots is compiled only if one of those reaches it, so a
   vault can be the source without the whole vault becoming the site.

   An empty list is not the same as an absent table: the table's presence is
   what turns selection on, and a table naming nothing would publish nothing,
   which is never what was meant. *)
let publish_from path fields =
  match List.assoc_opt "publish" fields with
  | None -> Ok []
  | Some (Otoml.TomlTable publish_fields | Otoml.TomlInlineTable publish_fields) ->
    let* () = check_closed path [ "from" ] publish_fields in
    (match List.assoc_opt "from" publish_fields with
     | None -> diagnostic path "publish.from is required when [publish] is present"
     | Some (Otoml.TomlArray values) ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | Otoml.TomlString value :: rest ->
           if value = "" then diagnostic path "publish.from entries may not be empty"
           else collect (value :: acc) rest
         | _ -> diagnostic path "publish.from must be an array of strings"
       in
       let* patterns = collect [] values in
       if patterns = [] then
         diagnostic path "publish.from names nothing, so nothing would be published"
       else Ok patterns
     | Some _ -> diagnostic path "publish.from must be an array of strings")
  | Some _ -> diagnostic path "publish must be a table"

let id_policy path fields =
  match List.assoc_opt "id" fields with
  | None -> Ok default_id_policy
  | Some (Otoml.TomlTable id_fields | Otoml.TomlInlineTable id_fields) ->
    let* () = check_closed path ["alphabet"; "width"; "scheme"; "prefix"; "mint"] id_fields in
    let field name default decode =
      match List.assoc_opt name id_fields with
      | None -> Ok default
      | Some value -> decode value
    in
    let* alphabet =
      field "alphabet" default_id_policy.alphabet (function
        | Otoml.TomlString value ->
          if String.length value < 2 then
            (* Base one has no positional notation: encoding would not
               terminate. *)
            diagnostic path "id.alphabet needs at least two digits"
          else if not (String.for_all id_char value) then
            diagnostic path "id.alphabet may only use [A-Za-z0-9._-]"
          else if not (alnum value.[0]) then
            diagnostic path "id.alphabet must begin with an alphanumeric digit"
          else if has_duplicate_chars value then
            diagnostic path "id.alphabet repeats a digit"
          else Ok value
        | _ -> diagnostic path "id.alphabet must be a string")
    in
    let* width =
      field "width" default_id_policy.width (function
        | Otoml.TomlInteger value when value >= 1 -> Ok value
        | Otoml.TomlInteger _ -> diagnostic path "id.width must be at least 1"
        | _ -> diagnostic path "id.width must be an integer")
    in
    let* scheme =
      field "scheme" default_id_policy.scheme (function
        | Otoml.TomlString "sequential" -> Ok Sequential
        | Otoml.TomlString "random" -> Ok Random
        | Otoml.TomlString _ -> diagnostic path "id.scheme must be \"sequential\" or \"random\""
        | _ -> diagnostic path "id.scheme must be a string")
    in
    let* prefix =
      field "prefix" default_id_policy.prefix (function
        | Otoml.TomlString "" -> Ok ""
        | Otoml.TomlString value ->
          if not (String.for_all id_char value) then
            diagnostic path "id.prefix may only use [A-Za-z0-9._-]"
          else if not (alnum value.[0]) then
            diagnostic path "id.prefix must begin with a letter or digit"
          else Ok value
        | _ -> diagnostic path "id.prefix must be a string")
    in
    let* mint =
      field "mint" default_id_policy.mint (function
        | Otoml.TomlString "build" -> Ok By_build
        | Otoml.TomlString "off" -> Ok Off
        | Otoml.TomlString _ -> diagnostic path "id.mint must be \"build\" or \"off\""
        | _ -> diagnostic path "id.mint must be a string")
    in
    Ok { alphabet; width; scheme; prefix; mint }
  | Some _ -> diagnostic path "id must be a table"

let load ~path =
  let* contents = read_file path in
  let* value = parse path contents in
  let* fields = table_fields path value in
  let* () =
    check_closed path
      ["version"; "forest"; "sources"; "output"; "target"; "id"; "publish"] fields
  in
  let* version = require_field path "version" fields in
  let* () =
    match version with
    | Otoml.TomlInteger 1 -> Ok ()
    | Otoml.TomlInteger _ -> diagnostic path "version must be 1"
    | _ -> diagnostic path "version must be an integer"
  in
  let* target = string_field path "target" fields in
  let* () =
    if target <> Forester_6.target then diagnostic path "unsupported target"
    else Ok ()
  in
  let* forest_reference = string_field path "forest" fields in
  let* forest_reference = relative_field path "forest" forest_reference in
  let* sources = relative_list_field path "sources" fields in
  let* output = string_field path "output" fields in
  let* output = relative_field path "output" output in
  let absolute_path =
    try Ok (Unix.realpath path)
    with
    | Unix.Unix_error (error, _, _) ->
      diagnostic path ("cannot resolve path: " ^ Unix.error_message error)
  in
  let* absolute_path = absolute_path in
  let directory = Filename.dirname absolute_path in
  let source_roots = resolved_pairs ~base:directory sources in
  let output_root = (output, Path_safe.resolve ~base:directory output) in
  let* () =
    if duplicate_relative sources then diagnostic path "duplicate source root"
    else check_source_output_overlap path source_roots (snd output_root)
  in
  let forest_path = Path_safe.resolve ~base:directory forest_reference in
  let* id = id_policy path fields in
  let* publish_from = publish_from path fields in
  let* forest = load_forest forest_path in
  let* () = check_output_tree path (snd output_root) forest.tree_roots in
  Ok {
    path = absolute_path;
    directory;
    forest;
    source_roots;
    output_root;
    target;
    id;
    publish_from;
  }
