(* mdbase v0.3 §04 names these "off", "warn" and "error". The last is spelled
   [Strict] here only so that it does not shadow [Result.Error]. *)
type validation = Off | Warn | Strict

type t = {
  spec_version : string;
  validation : validation;
  types_folder : string;
  explicit_type_keys : string list;
  id_field : string;
}

(* Pinned the way the Forester target is pinned, and for the same reason: a
   compiler that claims conformance has to name what it conforms to. *)
let supported_spec_version = "0.3.0"

let default = {
  spec_version = supported_spec_version;
  validation = Strict;
  types_folder = "_types";
  explicit_type_keys = [ "type"; "types" ];
  id_field = "id";
}

let file_name = "mdbase.yaml"

(* Settings tree-md reads and acts on. *)
let acted_on_settings =
  [ "validation"; "types_folder"; "explicit_type_keys"; "id_field" ]

(* Settings that are part of §04 but decide nothing here, because tree-md
   discovers its own sources: it compiles `.tree.md` under the `sources` roots
   named in tree-md.toml, not every record extension under the collection root.
   Reported rather than accepted in silence, so that setting one and seeing no
   effect is not a mystery. *)
let inert_settings =
  [ "record_extensions"; "include_subfolders"; "exclude" ]

(* Part of §04, and genuinely without effect here: tree-md computes no dates
   and loads no data contracts. *)
let accepted_settings = [ "timezone"; "contracts_folder" ]

let known_settings = acted_on_settings @ inert_settings @ accepted_settings

let diagnostic ?mdbase_code code path message =
  Diagnostic.make ?mdbase_code code (Span.Path path) message

let warn ?mdbase_code code path message =
  Diagnostic.warn ?mdbase_code code (Span.Path path) message

let read_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok contents
  | exception Sys_error message ->
    Error [ diagnostic TM401 path ("cannot read " ^ file_name ^ ": " ^ message) ]

let string_field node name =
  match Yaml_json.field node name with
  | None -> None
  | Some value -> Yaml_json.as_text value

let string_list_field node name =
  match Yaml_json.field node name with
  | None -> None
  | Some { Yaml_json.value = Yaml_json.List items; _ } ->
    Some (List.filter_map Yaml_json.as_text items)
  | Some value -> Option.map (fun text -> [ text ]) (Yaml_json.as_text value)

(* The file is a YAML document rather than front matter, so it is read by
   wrapping it in the delimiters Frontmatter.parse expects. That keeps one YAML
   reader in the compiler, with its spans and its refusal of anchors and
   aliases, instead of two that could disagree. *)
let parse_document ~path contents =
  let wrapped = "---\n" ^ contents ^ "\n---\n" in
  match Source.of_string ~path wrapped with
  | Error _ -> Error [ diagnostic TM401 path (file_name ^ " is not valid UTF-8") ]
  | Ok source -> (
    match Frontmatter.parse source with
    | Error diagnostics ->
      (* Re-point at the file: the spans are into the wrapper, not the note. *)
      Error
        (List.map
           (fun (d : Diagnostic.t) ->
             diagnostic TM401 path (file_name ^ ": " ^ d.Diagnostic.message))
           diagnostics)
    | Ok (parsed, _warnings) -> Ok parsed.Frontmatter.frontmatter)

let parse_validation ~path value =
  match value with
  | "off" -> Ok Off
  | "warn" -> Ok Warn
  | "error" -> Ok Strict
  | other ->
    Error
      [ diagnostic TM401 path
          ("settings.validation must be \"off\", \"warn\" or \"error\", not \""
           ^ other ^ "\"") ]

let load ~directory =
  let path = Filename.concat directory file_name in
  if not (Sys.file_exists path) then Ok (default, [])
  else
    match read_file path with
    | Error diagnostics -> Error diagnostics
    | Ok contents -> (
      match parse_document ~path contents with
      | Error diagnostics -> Error diagnostics
      | Ok None -> Ok (default, [])
      | Ok (Some node) -> (
        let warnings = ref [] in
        let add_warning d = warnings := d :: !warnings in
        (* §04: unknown configuration keys warn; loading continues. *)
        List.iter
          (fun (name, _span) ->
            if
              not
                (List.mem name [ "spec_version"; "settings" ]
                 || (String.length name >= 2 && String.sub name 0 2 = "x-"))
            then
              add_warning
                (warn TM401 path
                   ("unknown " ^ file_name ^ " key \"" ^ name ^ "\"")))
          (Yaml_json.keys node);
        match string_field node "spec_version" with
        | None ->
          Error
            [ diagnostic TM401 path
                (file_name ^ " must declare spec_version; this tree-md \
                  supports " ^ supported_spec_version) ]
        | Some declared ->
          (* §04: during major-zero the minor component is the compatibility
             boundary, and a rejecting tool must report the exact identifier
             it supports. *)
          let minor_of value =
            match String.split_on_char '.' value with
            | major :: minor :: _ -> Some (major ^ "." ^ minor)
            | _ -> None
          in
          if minor_of declared <> minor_of supported_spec_version then
            Error
              [ diagnostic TM401 path
                  (file_name ^ " declares spec_version \"" ^ declared
                   ^ "\"; this tree-md supports " ^ supported_spec_version) ]
          else
            let settings =
              match Yaml_json.field node "settings" with
              | Some ({ Yaml_json.value = Yaml_json.Assoc _; _ } as s) -> Some s
              | _ -> None
            in
            let config = { default with spec_version = declared } in
            match settings with
            | None -> Ok (config, List.rev !warnings)
            | Some settings ->
              List.iter
                (fun (name, _span) ->
                  if String.length name >= 2 && String.sub name 0 2 = "x-" then ()
                  else if List.mem name inert_settings then
                    add_warning
                      (warn TM401 path
                         ("settings." ^ name ^ " has no effect here: tree-md \
                           compiles the `.tree.md` files under the source \
                           roots named in tree-md.toml"))
                  else if not (List.mem name known_settings) then
                    add_warning
                      (warn TM401 path
                         ("unknown setting \"settings." ^ name ^ "\"")))
                (Yaml_json.keys settings);
              let validation_result =
                match string_field settings "validation" with
                | None -> Ok config.validation
                | Some value -> parse_validation ~path value
              in
              (match validation_result with
               | Error diagnostics -> Error diagnostics
               | Ok validation ->
                 let types_folder =
                   Option.value ~default:config.types_folder
                     (string_field settings "types_folder")
                 in
                 let explicit_type_keys =
                   Option.value ~default:config.explicit_type_keys
                     (string_list_field settings "explicit_type_keys")
                 in
                 let id_field =
                   Option.value ~default:config.id_field
                     (string_field settings "id_field")
                 in
                 Ok
                   ( { config with validation; types_folder;
                       explicit_type_keys; id_field },
                     List.rev !warnings ))))
