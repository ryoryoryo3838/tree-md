(* allow: SIZE_OK — the reviewed Task 14 interface mandates this state machine
   in a single transaction.ml module; the closed decoder mirrors manifest.ml
   (accepted at 224 non-blank lines) and roll_forward is an indivisible
   per-operation state table that the brief requires verbatim.

   Closed crash-recovery journal for generated outputs. The journal records
   the base and new manifest hashes plus one closed record per sorted
   operation, so an interrupted build can be deterministically rolled forward
   from observed on-disk state. Like the manifest, the schema is closed, the
   encoding is canonical, and every field is validated on decode: recovery
   never trusts hand-edited journal files. *)

let format_version = 1

type operation = {
  output : Path_safe.relative;
  old_sha256 : string option;
  new_sha256 : string option;
  temporary : Path_safe.relative option;
}

type t = {
  format : int;
  base_manifest_sha256 : string option;
  new_manifest_sha256 : string;
  new_manifest_temporary : Path_safe.relative;
  operations : operation list;
}

type observed = Missing | Hash of string
type action =
  | Ensure_parent of Path_safe.relative
  | Install_output of { temporary : Path_safe.relative; output : Path_safe.relative; sha256 : string }
  | Delete_output of { output : Path_safe.relative; old_sha256 : string }
  | Install_manifest of { temporary : Path_safe.relative; sha256 : string }
  | Remove_stage of Path_safe.relative
  | Remove_journal

(* Transaction ids name the staging directory (.tree-md-stage/<id>/), so they
   are restricted to characters that cannot change the meaning of a path. *)
let valid_transaction_id id =
  id <> ""
  && String.for_all
       (function
         | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
         | _ -> false)
       id

let relative value =
  match Path_safe.relative value with
  | Ok path -> path
  | Error message -> invalid_arg (value ^ ": " ^ message)

let compare_operation (a : operation) (b : operation) =
  String.compare (Path_safe.to_string a.output) (Path_safe.to_string b.output)

let sort_operations operations = List.sort compare_operation operations

(* ── Creation from a manifest diff ── *)

let create ~transaction_id ~old_manifest ~(new_manifest : Manifest.t)
    (operations : Manifest.operation list) =
  if not (valid_transaction_id transaction_id) then
    invalid_arg
      ("Transaction.create: transaction id must match [A-Za-z0-9_-]+: "
      ^ transaction_id);
  let stage = relative (".tree-md-stage/" ^ transaction_id) in
  let manifest_temporary = Path_safe.append stage (relative "manifest.tmp") in
  let new_manifest_sha256 = Manifest.sha256 (Manifest.encode new_manifest) in
  let base_manifest_sha256 =
    Option.map (fun manifest -> Manifest.sha256 (Manifest.encode manifest))
      old_manifest
  in
  let operations =
    List.filter_map
      (function
        | Manifest.Unchanged _ -> None
        | Manifest.Create entry ->
          let output = entry.Manifest.output in
          Some
            { output;
              old_sha256 = None;
              new_sha256 = Some entry.Manifest.sha256;
              temporary =
                Some
                  (Path_safe.append stage
                     (relative (Path_safe.to_string output ^ ".tmp"))) }
        | Manifest.Replace { old_entry; new_entry } ->
          let output = new_entry.Manifest.output in
          Some
            { output;
              old_sha256 = Some old_entry.Manifest.sha256;
              new_sha256 = Some new_entry.Manifest.sha256;
              temporary =
                Some
                  (Path_safe.append stage
                     (relative (Path_safe.to_string output ^ ".tmp"))) }
        | Manifest.Delete entry ->
          let output = entry.Manifest.output in
          Some
            { output;
              old_sha256 = Some entry.Manifest.sha256;
              new_sha256 = None;
              temporary = None })
      operations
  in
  { format = format_version;
    base_manifest_sha256;
    new_manifest_sha256;
    new_manifest_temporary = manifest_temporary;
    operations = sort_operations operations }

(* ── Canonical encoding ── *)

let json_of_operation (operation : operation) =
  `Assoc
    [ "output", `String (Path_safe.to_string operation.output);
      "old_sha256",
      (match operation.old_sha256 with
       | Some hash -> `String hash
       | None -> `Null);
      "new_sha256",
      (match operation.new_sha256 with
       | Some hash -> `String hash
       | None -> `Null);
      "temporary",
      (match operation.temporary with
       | Some path -> `String (Path_safe.to_string path)
       | None -> `Null) ]

let encode (transaction : t) =
  let json =
    `Assoc
      [ "format", `Int transaction.format;
        "base_manifest_sha256",
        (match transaction.base_manifest_sha256 with
         | Some hash -> `String hash
         | None -> `Null);
        "new_manifest_sha256", `String transaction.new_manifest_sha256;
        "new_manifest_temporary",
        `String (Path_safe.to_string transaction.new_manifest_temporary);
        "operations",
        `List (List.map json_of_operation (sort_operations transaction.operations)) ]
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
  [ Diagnostic.make TM403 (Span.Path path) (path ^ ": " ^ message) ]

let field_error path message = Error (invalid path message)

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

let is_lower_hex = function
  | '0' .. '9' | 'a' .. 'f' -> true
  | _ -> false

let valid_sha256 hash =
  String.length hash = 64 && String.for_all is_lower_hex hash

let has_suffix ~suffix value =
  let value_length = String.length value in
  let suffix_length = String.length suffix in
  value_length >= suffix_length
  && String.sub value (value_length - suffix_length) suffix_length = suffix

let has_tree_md_component path =
  List.exists
    (fun component ->
      String.length component >= 8 && String.sub component 0 8 = ".tree-md")
    (String.split_on_char '/' path)

let decode_optional_hash path label = function
  | `Null -> Ok None
  | `String hash ->
    if valid_sha256 hash then Ok (Some hash)
    else field_error path (label ^ " must be 64 lowercase hexadecimal digits")
  | _ -> field_error path (label ^ " must be a string or null")

let decode_required_hash path label = function
  | `String hash ->
    if valid_sha256 hash then Ok hash
    else field_error path (label ^ " must be 64 lowercase hexadecimal digits")
  | _ -> field_error path (label ^ " must be a string")

(* The staged manifest is always exactly .tree-md-stage/<txn-id>/manifest.tmp,
   and its transaction id names the whole staging directory. *)
let decode_manifest_temporary path = function
  | `String temporary ->
    (match Path_safe.relative temporary with
     | Error message ->
       field_error path ("invalid new_manifest_temporary path: " ^ message)
     | Ok relative_path ->
       (match String.split_on_char '/' temporary with
        | [ ".tree-md-stage"; id; "manifest.tmp" ]
          when valid_transaction_id id ->
          Ok (relative_path, id)
        | _ ->
          field_error path
            "new_manifest_temporary must be .tree-md-stage/<txn-id>/manifest.tmp"))
  | _ -> field_error path "new_manifest_temporary must be a string"

let decode_optional_path path label = function
  | `Null -> Ok None
  | `String value ->
    (match Path_safe.relative value with
     | Ok relative_path -> Ok (Some relative_path)
     | Error message -> field_error path (label ^ " path: " ^ message))
  | _ -> field_error path (label ^ " must be a string or null")

let validate_output path output =
  match Path_safe.relative output with
  | Error message -> field_error path ("invalid output path: " ^ message)
  | Ok relative_path ->
    if not (has_suffix ~suffix:".tree" output) then
      field_error path "output path must end in .tree"
    else if has_tree_md_component output then
      field_error path "output path uses a reserved .tree-md component"
    else Ok relative_path

(* Exactly three states are valid: create (old null, new and temporary set),
   replace (old, new, and temporary set with differing hashes), and delete
   (old set, new and temporary null). Every other combination is rejected. *)
let validate_state path output old_sha256 new_sha256 temporary =
  match old_sha256, new_sha256, temporary with
  | None, Some _, Some _ -> Ok ()
  | Some old_hash, Some new_hash, Some _ ->
    if old_hash = new_hash then
      field_error path ("operation for " ^ output ^ " does not change content")
    else Ok ()
  | Some _, None, None -> Ok ()
  | _ ->
    field_error path
      ("operation for " ^ output
      ^ " must be a create, replace, or delete with consistent null fields")

let decode_operation path id = function
  | `Assoc assoc ->
    let* fields =
      consume_keys ~known:[ "output"; "old_sha256"; "new_sha256"; "temporary" ]
        ~unknown_label:"unknown operation field: "
        ~missing_label:"missing operation field: "
        ~duplicate_label:"duplicate operation field: "
        ~lift:(invalid path) assoc
    in
    let require name =
      match List.assoc_opt name fields with
      | Some value -> Ok value
      | None -> field_error path ("missing operation field: " ^ name)
    in
    let* output_value = require "output" in
    let* old_value = require "old_sha256" in
    let* new_value = require "new_sha256" in
    let* temporary_value = require "temporary" in
    let* output = decode_string path "operation output" output_value in
    let* old_sha256 = decode_optional_hash path "old_sha256" old_value in
    let* new_sha256 = decode_optional_hash path "new_sha256" new_value in
    let* temporary = decode_optional_path path "temporary" temporary_value in
    let* output_relative = validate_output path output in
    let* () = validate_state path output old_sha256 new_sha256 temporary in
    let* temporary_relative =
      match temporary, new_sha256 with
      | Some temporary_path, Some _ ->
        let expected = ".tree-md-stage/" ^ id ^ "/" ^ output ^ ".tmp" in
        if Path_safe.to_string temporary_path = expected then
          Ok (Some temporary_path)
        else field_error path ("temporary must be " ^ expected)
      | None, None -> Ok None
      | _ ->
        field_error path
          ("operation for " ^ output
          ^ " must be a create, replace, or delete with consistent null fields")
    in
    Ok { output = output_relative; old_sha256; new_sha256; temporary = temporary_relative }
  | _ -> field_error path "operation must be an object"

let decode_operations path id = function
  | `List items ->
    let rec loop seen_outputs acc = function
      | [] -> Ok (List.rev acc)
      | item :: rest ->
        let* operation = decode_operation path id item in
        let output = Path_safe.to_string operation.output in
        if List.mem output seen_outputs then
          field_error path ("duplicate operation output: " ^ output)
        else loop (output :: seen_outputs) (operation :: acc) rest
    in
    let* operations = loop [] [] items in
    Ok (sort_operations operations)
  | _ -> field_error path "operations must be an array"

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
      consume_keys
        ~known:
          [ "format"; "base_manifest_sha256"; "new_manifest_sha256";
            "new_manifest_temporary"; "operations" ]
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
    let* base_value = require "base_manifest_sha256" in
    let* new_value = require "new_manifest_sha256" in
    let* manifest_temp_value = require "new_manifest_temporary" in
    let* operations_value = require "operations" in
    let* format = decode_format path format_value in
    let* base_manifest_sha256 =
      decode_optional_hash path "base_manifest_sha256" base_value
    in
    let* new_manifest_sha256 =
      decode_required_hash path "new_manifest_sha256" new_value
    in
    let* new_manifest_temporary, transaction_id =
      decode_manifest_temporary path manifest_temp_value
    in
    let* operations = decode_operations path transaction_id operations_value in
    Ok
      { format;
        base_manifest_sha256;
        new_manifest_sha256;
        new_manifest_temporary;
        operations }
  | Ok _ -> field_error path "transaction must be a JSON object"

(* ── Deterministic roll-forward planning ── *)

(* create and decode guarantee new_manifest_temporary has the exact shape
   .tree-md-stage/<txn-id>/manifest.tmp, so extraction is total for any
   journal the planner could receive; a stray value is a TM403 precondition. *)
let stage_root (t : t) =
  match String.split_on_char '/' (Path_safe.to_string t.new_manifest_temporary)
  with
  | [ ".tree-md-stage"; id; "manifest.tmp" ] when valid_transaction_id id ->
    (match Path_safe.relative (".tree-md-stage/" ^ id) with
     | Ok path -> Ok path
     | Error message ->
       Error
         (invalid (Path_safe.to_string t.new_manifest_temporary)
            ("invalid staged manifest path: " ^ message)))
  | _ ->
    Error
      (invalid (Path_safe.to_string t.new_manifest_temporary)
         "new_manifest_temporary is not inside a .tree-md-stage transaction directory")

(* The dirname of a validated relative output is itself a valid relative
   path, so the error branch is unreachable for journaled outputs. *)
let parent_of_output (output : Path_safe.relative) =
  let output_string = Path_safe.to_string output in
  match String.rindex_opt output_string '/' with
  | None -> None
  | Some index ->
    (match Path_safe.relative (String.sub output_string 0 index) with
     | Ok parent -> Some parent
     | Error _ -> None)

let roll_forward (t : t) ~current_manifest ~output ~temporary =
  let* stage = stage_root t in
  let diagnostics = ref [] in
  let add path message =
    diagnostics :=
      Diagnostic.make TM403 (Span.Path path) (path ^ ": " ^ message)
      :: !diagnostics
  in
  let manifest_path = Path_safe.to_string t.new_manifest_temporary in
  let completed =
    match current_manifest with
    | Hash hash -> hash = t.new_manifest_sha256
    | Missing -> false
  in
  (* Manifest-level precondition: the current manifest may be the recorded
     new state (commit completed) or the recorded base state (roll forward);
     a first build has no base, so only absence is acceptable. *)
  (match current_manifest with
   | Hash hash when hash = t.new_manifest_sha256 -> ()
   | Hash hash ->
     (match t.base_manifest_sha256 with
      | Some base_hash when base_hash = hash -> ()
      | _ ->
        add manifest_path
          "current manifest matches neither the base nor the new state")
   | Missing ->
     (match t.base_manifest_sha256 with
      | None -> ()
      | Some _ ->
        add manifest_path
          "current manifest is missing but the journal records a base manifest"));
  if completed then begin
    (* The commit finished: verify every output is in its recorded new state,
       then clean up the stage directory and the journal. *)
    List.iter
      (fun op ->
        match op.old_sha256, op.new_sha256 with
        | None, Some new_hash | Some _, Some new_hash ->
          (match output op.output with
           | Hash hash when hash = new_hash -> ()
           | Missing -> add (Path_safe.to_string op.output) "committed output is missing"
           | Hash _ ->
             add (Path_safe.to_string op.output)
               "committed output does not match the recorded new content")
        | Some _, None ->
          (match output op.output with
           | Missing -> ()
           | Hash _ ->
             add (Path_safe.to_string op.output)
               "committed delete output is still present")
        | _ ->
          add (Path_safe.to_string op.output)
            "operation does not describe a create, replace, or delete")
      t.operations;
    match !diagnostics with
    | [] -> Ok [ Remove_stage stage; Remove_journal ]
    | _ :: _ -> Error (List.rev !diagnostics)
  end
  else begin
    (* Roll forward from the recorded base state: the recorded temporary
       manifest must exist with the new hash before any output is changed. *)
    (match temporary t.new_manifest_temporary with
     | Hash hash when hash = t.new_manifest_sha256 -> ()
     | Hash _ ->
       add manifest_path "temporary manifest does not match new_manifest_sha256"
     | Missing -> add manifest_path "missing required temporary manifest");
    let transitions = ref [] in
    let install_outputs = ref [] in
    List.iter
      (fun op ->
        match op.old_sha256, op.new_sha256, op.temporary with
        | None, Some new_hash, Some temp ->
          (* create: absent or already new; otherwise the new content must be
             staged. *)
          (match output op.output with
           | Missing ->
             (match temporary temp with
              | Hash hash when hash = new_hash ->
                transitions :=
                  Install_output
                    { temporary = temp; output = op.output; sha256 = new_hash }
                  :: !transitions;
                install_outputs := op.output :: !install_outputs
              | Hash _ ->
                add (Path_safe.to_string temp)
                  "temporary does not match the recorded new content"
              | Missing -> add (Path_safe.to_string temp) "missing required temporary")
           | Hash hash when hash = new_hash -> ()
           | Hash _ ->
             add (Path_safe.to_string op.output)
               "create output is neither absent nor the recorded new content")
        | Some old_hash, Some new_hash, Some temp ->
          (* replace: only the old or the new hash is acceptable. *)
          (match output op.output with
           | Hash hash when hash = old_hash ->
             (match temporary temp with
              | Hash hash when hash = new_hash ->
                transitions :=
                  Install_output
                    { temporary = temp; output = op.output; sha256 = new_hash }
                  :: !transitions;
                install_outputs := op.output :: !install_outputs
              | Hash _ ->
                add (Path_safe.to_string temp)
                  "temporary does not match the recorded new content"
              | Missing -> add (Path_safe.to_string temp) "missing required temporary")
           | Hash hash when hash = new_hash -> ()
           | Missing -> add (Path_safe.to_string op.output) "replace output is missing"
           | Hash _ ->
             add (Path_safe.to_string op.output)
               "replace output matches neither the old nor the new content")
        | Some old_hash, None, None ->
          (* delete: old content or absence. *)
          (match output op.output with
           | Hash hash when hash = old_hash ->
             transitions :=
               Delete_output { output = op.output; old_sha256 = old_hash }
               :: !transitions
           | Missing -> ()
           | Hash _ ->
             add (Path_safe.to_string op.output)
               "delete output is neither the old content nor absent")
        | _ ->
          add (Path_safe.to_string op.output)
            "operation does not describe a create, replace, or delete")
      t.operations;
    match !diagnostics with
    | _ :: _ -> Error (List.rev !diagnostics)
    | [] ->
      let parents =
        List.rev !install_outputs
        |> List.filter_map parent_of_output
        |> List.sort_uniq (fun a b ->
             String.compare (Path_safe.to_string a) (Path_safe.to_string b))
      in
      Ok
        (List.map (fun parent -> Ensure_parent parent) parents
        @ List.rev !transitions
        @ [ Install_manifest
              { temporary = t.new_manifest_temporary;
                sha256 = t.new_manifest_sha256 };
            Remove_stage stage;
            Remove_journal ])
  end
