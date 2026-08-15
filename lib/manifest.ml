(* Versioned closed manifest for generated outputs. The manifest is the
   only record of compiler ownership over the output root, so every field
   is validated on decode: later state transitions never trust hand-edited
   files. The schema is closed, the encoding is canonical, and the diff is a
   pure function of two manifests. *)

let current_version = Version.current
let format_version = 1

type entry = {
  source : Path_safe.relative;
  output : Path_safe.relative;
  sha256 : string;
}

type t = {
  format : int;
  compiler : string;
  target : string;
  files : entry list;
}

type operation =
  | Create of entry
  | Replace of { old_entry : entry; new_entry : entry }
  | Delete of entry
  | Unchanged of entry

let has_suffix ~suffix value =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false

let valid_sha256 hash =
  String.length hash = 64 && String.for_all is_lower_hex hash

(* The output-root names .tree-md-manifest.json, .tree-md-transaction.json,
   .tree-md.lock, and .tree-md-stage/ are reserved for compiler state, so a
   generated output path may not use any component beginning with .tree-md. *)
let has_tree_md_component path =
  List.exists
    (fun component ->
      String.length component >= 8 && String.sub component 0 8 = ".tree-md")
    (String.split_on_char '/' path)

let compare_entry (a : entry) (b : entry) =
  let by_output =
    String.compare (Path_safe.to_string a.output) (Path_safe.to_string b.output)
  in
  if by_output <> 0 then by_output
  else
    String.compare (Path_safe.to_string a.source) (Path_safe.to_string b.source)

let sort_files files = List.sort compare_entry files

let of_expected expecteds =
  let files =
    List.map
      (fun (record : Compiler.expected) ->
        { source = record.source_config_relative;
          output = record.output_relative;
          sha256 = record.sha256 })
      expecteds
  in
  { format = format_version;
    compiler = current_version;
    target = Forester_6.target;
    files = sort_files files }

let json_of_entry (entry : entry) =
  `Assoc
    [ "source", `String (Path_safe.to_string entry.source);
      "output", `String (Path_safe.to_string entry.output);
      "sha256", `String entry.sha256 ]

let encode (manifest : t) =
  let json =
    `Assoc
      [ "format", `Int manifest.format;
        "compiler", `String manifest.compiler;
        "target", `String manifest.target;
        "files", `List (List.map json_of_entry (sort_files manifest.files)) ]
  in
  let serialized = Yojson.Safe.pretty_to_string ~std:true json in
  let serialized =
    let length = String.length serialized in
    if length > 0 && serialized.[length - 1] = '\n' then
      String.sub serialized 0 (length - 1)
    else serialized
  in
  serialized ^ "\n"

(* ── Closed decoding ── *)

let ( let* ) = Result.bind

let invalid path message =
  [ Diagnostic.make TM402 (Span.Path path) (path ^ ": " ^ message) ]

let field_error path message = Error (invalid path message)

(* Consume each known key exactly once: reject unknown keys, duplicate keys,
   and missing required keys, in that order. Returns the consumed (key, value)
   pairs in their original order, lifting every failure through [lift]. *)
let consume_keys ~known ~unknown_label ~missing_label ~duplicate_label
    ~lift assoc =
  let rec loop seen acc = function
    | [] ->
      (match List.find_opt (fun key -> not (List.mem key seen)) known with
       | None -> Ok (List.rev acc)
       | Some key -> Error (lift (missing_label ^ key)))
    | (key, value) :: rest ->
      if not (List.mem key known) then Error (lift (unknown_label ^ key))
      else if List.mem key seen then Error (lift (duplicate_label ^ key))
      else loop (key :: seen) ((key, value) :: acc) rest
  in
  loop [] [] assoc

let decode_string path label = function
  | `String value -> Ok value
  | _ -> field_error path (label ^ " must be a string")

let decode_format path = function
  | `Int 1 -> Ok 1
  | `Int version ->
    field_error path (Printf.sprintf "unsupported format version %d" version)
  | _ -> field_error path "format must be an integer"

let validate_entry_paths path source output =
  match Path_safe.relative source with
  | Error message -> field_error path ("invalid source path: " ^ message)
  | Ok source_relative ->
    if not (has_suffix ~suffix:".tree.md" source) then
      field_error path "source path must end in .tree.md"
    else
      match Path_safe.relative output with
      | Error message -> field_error path ("invalid output path: " ^ message)
      | Ok output_relative ->
        if not (has_suffix ~suffix:".tree" output) then
          field_error path "output path must end in .tree"
        else if has_tree_md_component output then
          field_error path "output path uses a reserved .tree-md component"
        else Ok (source_relative, output_relative)

let decode_entry path = function
  | `Assoc assoc ->
    let* fields =
      consume_keys ~known:[ "source"; "output"; "sha256" ]
        ~unknown_label:"unknown entry field: "
        ~missing_label:"missing entry field: "
        ~duplicate_label:"duplicate entry field: "
        ~lift:(invalid path) assoc
    in
    let require name =
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> field_error path ("missing entry field: " ^ name)
    in
    let* source_value = require "source" in
    let* output_value = require "output" in
    let* hash_value = require "sha256" in
    let* source = decode_string path "entry source" source_value in
    let* output = decode_string path "entry output" output_value in
    let* sha256 = decode_string path "entry sha256" hash_value in
    if not (valid_sha256 sha256) then
      field_error path "sha256 must be 64 lowercase hexadecimal digits"
    else
      let* source_relative, output_relative =
        validate_entry_paths path source output
      in
      Ok { source = source_relative; output = output_relative; sha256 }
  | _ -> field_error path "manifest entry must be an object"

let decode_files path = function
  | `List items ->
    let rec loop entries sources outputs = function
      | [] -> Ok (List.rev entries)
      | item :: rest ->
        let* entry = decode_entry path item in
        let source = Path_safe.to_string entry.source in
        let output = Path_safe.to_string entry.output in
        if List.mem source sources then
          field_error path ("duplicate source entry: " ^ source)
        else if List.mem output outputs then
          field_error path ("duplicate output entry: " ^ output)
        else loop (entry :: entries) (source :: sources) (output :: outputs) rest
    in
    let* files = loop [] [] [] items in
    Ok (sort_files files)
  | _ -> field_error path "files must be an array"

let decode ~path contents =
  let json =
    try Ok (Yojson.Safe.from_string contents)
    with Yojson.Json_error message ->
      field_error path ("malformed JSON: " ^ message)
  in
  match json with
  | Error diagnostics -> Error diagnostics
  | Ok (`Assoc assoc) ->
    let* fields =
      consume_keys ~known:[ "format"; "compiler"; "target"; "files" ]
        ~unknown_label:"unknown field: "
        ~missing_label:"missing field: "
        ~duplicate_label:"duplicate field: "
        ~lift:(invalid path) assoc
    in
    let require name =
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> field_error path ("missing field: " ^ name)
    in
    let* format_value = require "format" in
    let* compiler_value = require "compiler" in
    let* target_value = require "target" in
    let* files_value = require "files" in
    let* format = decode_format path format_value in
    let* compiler = decode_string path "compiler" compiler_value in
    let* target = decode_string path "target" target_value in
    let* files = decode_files path files_value in
    Ok { format; compiler; target; files }
  | Ok _ -> field_error path "manifest must be a JSON object"

(* ── Expected-state diff ── *)

let diff ~old ~(next : t) =
  let previous =
    match old with None -> [] | Some manifest -> sort_files manifest.files
  in
  let rec merge acc previous upcoming =
    match previous, upcoming with
    | [], [] -> List.rev acc
    | old_entry :: rest, [] -> merge (Delete old_entry :: acc) rest []
    | [], new_entry :: rest -> merge (Create new_entry :: acc) [] rest
    | old_entry :: olds, new_entry :: news ->
      let order = compare_entry old_entry new_entry in
      if order < 0 then merge (Delete old_entry :: acc) olds upcoming
      else if order > 0 then merge (Create new_entry :: acc) previous news
      else if old_entry.sha256 = new_entry.sha256 then
        merge (Unchanged new_entry :: acc) olds news
      else merge (Replace { old_entry; new_entry } :: acc) olds news
  in
  merge [] previous next.files

let sha256 bytes =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)
