(* ── structured predicates (§07 match.where) ── *)

type comparison = Eq | Neq | Gt | Gte | Lt | Lte

type predicate =
  | Compare of comparison * Yojson.Safe.t
  | Contains of Yojson.Safe.t
  | Contains_all of Yojson.Safe.t list
  | Contains_any of Yojson.Safe.t list
  | Starts_with of string
  | Ends_with of string
  | Matches of string * Re.re
  | Exists of bool

type t = {
  name : string;
  path : string;
  schema : Json_schema.t;
  (* [] means the member was absent, which places no constraint. *)
  path_globs : string list;
  fields_present : string list;
  where : (string * predicate list) list;
  has_match : bool;
  read_defaults : (string * Yojson.Safe.t) list;
}

let name t = t.name
let path t = t.path
let read_defaults t = t.read_defaults
let validate t value = Json_schema.validate t.schema value

let diagnostic ?secondary ?mdbase_code code path message =
  Diagnostic.make ?secondary ?mdbase_code code (Span.Path path) message

let warn ?mdbase_code code path message =
  Diagnostic.warn ?mdbase_code code (Span.Path path) message

(* ── the sections this implementation acts on ── *)

let supported_sections = [ "kind"; "name"; "version"; "match"; "schema"; "collection" ]

(* Declared by §05 but not acted on here. Refused rather than accepted, so a
   type file cannot claim a constraint nothing enforces. *)
let unsupported_sections =
  [ ("lifecycle", "tree-md mints addresses from the [id] policy in tree-md.toml");
    ("runtime", "tree-md runs no workflows");
    ("migrations", "tree-md does not migrate records");
    ("implements", "tree-md loads no data contracts") ]

let supported_match_members = [ "path_glob"; "fields_present"; "where" ]
let supported_collection_members = [ "read_defaults"; "display" ]

let unsupported_collection_members =
  [ ("unique", "tree-md enforces address uniqueness across the whole forest \
                itself, and reports a clash as TM201");
    ("links", "tree-md resolves every reference closed-world already, and \
               reports an unresolved one as TM202");
    ("path", "tree-md names an output after the tree's address");
    ("projections", "projections need the CEL profile, which tree-md does not \
                     implement") ]

(* ── reading a type file ── *)

let ( let* ) = Result.bind

let field node name = Yaml_json.field node name

let text_of node = Yaml_json.as_text node

let string_list (node : Yaml_json.t) =
  match node.Yaml_json.value with
  | Yaml_json.List items -> List.filter_map text_of items
  | _ -> Option.to_list (text_of node)

let comparison_of = function
  | "eq" -> Some Eq
  | "neq" -> Some Neq
  | "gt" -> Some Gt
  | "gte" -> Some Gte
  | "lt" -> Some Lt
  | "lte" -> Some Lte
  | _ -> None

let parse_predicates ~path (selector : string) (node : Yaml_json.t) =
  match node.Yaml_json.value with
  (* A direct value is deep equality. *)
  | Yaml_json.Assoc entries ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (entry : Yaml_json.field) :: rest -> (
        let operand = Yaml_json.to_yojson entry.Yaml_json.value in
        match entry.Yaml_json.name with
        | op when comparison_of op <> None ->
          loop (Compare (Option.get (comparison_of op), operand) :: acc) rest
        | "contains" -> loop (Contains operand :: acc) rest
        | "containsAll" ->
          loop (Contains_all (match operand with `List l -> l | v -> [ v ]) :: acc) rest
        | "containsAny" ->
          loop (Contains_any (match operand with `List l -> l | v -> [ v ]) :: acc) rest
        | "startsWith" -> (
          match operand with
          | `String s -> loop (Starts_with s :: acc) rest
          | _ -> Error [ diagnostic TM401 path "startsWith needs a string" ])
        | "endsWith" -> (
          match operand with
          | `String s -> loop (Ends_with s :: acc) rest
          | _ -> Error [ diagnostic TM401 path "endsWith needs a string" ])
        | "matches" -> (
          match operand with
          | `String source -> (
            match Re.Pcre.re source with
            | regex -> loop (Matches (source, Re.compile regex) :: acc) rest
            | exception _ ->
              Error
                [ diagnostic TM401 path
                    ("match.where." ^ selector ^ ".matches: \"" ^ source
                     ^ "\" is not a valid regular expression") ])
          | _ -> Error [ diagnostic TM401 path "matches needs a string" ])
        | "exists" -> (
          match operand with
          | `Bool b -> loop (Exists b :: acc) rest
          | _ -> Error [ diagnostic TM401 path "exists needs a boolean" ])
        | other ->
          Error
            [ diagnostic TM401 path
                ("match.where." ^ selector ^ ": unknown operator \"" ^ other
                 ^ "\"") ])
    in
    loop [] entries
  | _ -> Ok [ Compare (Eq, Yaml_json.to_yojson node) ]

let parse_match ~path node =
  match node with
  | None -> Ok ([], [], [], false)
  | Some node ->
    let unknown =
      List.filter
        (fun (name, _) -> not (List.mem name supported_match_members))
        (Yaml_json.keys node)
    in
    (match unknown with
     | ("expr", _) :: _ ->
       Error
         [ diagnostic ~mdbase_code:"unsupported_profile" TM401 path
             "match.expr needs the cel_match conformance profile, which \
              tree-md does not implement" ]
     | (other, _) :: _ ->
       Error
         [ diagnostic TM401 path ("unknown match member \"" ^ other ^ "\"") ]
     | [] ->
       let globs =
         match field node "path_glob" with
         | None -> []
         | Some value -> string_list value
       in
       let fields_present =
         match field node "fields_present" with
         | None -> []
         | Some value -> string_list value
       in
       let* where =
         match field node "where" with
         | None -> Ok []
         | Some ({ Yaml_json.value = Yaml_json.Assoc entries; _ }) ->
           let rec loop acc = function
             | [] -> Ok (List.rev acc)
             | (entry : Yaml_json.field) :: rest ->
               let* predicates =
                 parse_predicates ~path entry.Yaml_json.name entry.Yaml_json.value
               in
               loop ((entry.Yaml_json.name, predicates) :: acc) rest
           in
           loop [] entries
         | Some _ -> Error [ diagnostic TM401 path "match.where must be a mapping" ]
       in
       Ok (globs, fields_present, where, true))

let parse_collection ~path node =
  match node with
  | None -> Ok []
  | Some node ->
    let members = Yaml_json.keys node in
    let refused =
      List.find_map
        (fun (name, _) ->
          List.assoc_opt name unsupported_collection_members
          |> Option.map (fun why -> (name, why)))
        members
    in
    (match refused with
     | Some (name, why) ->
       Error
         [ diagnostic ~mdbase_code:"unsupported_profile" TM401 path
             ("collection." ^ name ^ " is not enforced by tree-md: " ^ why) ]
     | None ->
       let unknown =
         List.find_opt
           (fun (name, _) ->
             not (List.mem name supported_collection_members)
             && not (String.length name >= 2 && String.sub name 0 2 = "x-"))
           members
       in
       (match unknown with
        | Some (name, _) ->
          Error
            [ diagnostic TM401 path
                ("unknown collection member \"" ^ name ^ "\"") ]
        | None ->
          (match field node "read_defaults" with
           | None -> Ok []
           | Some ({ Yaml_json.value = Yaml_json.Assoc entries; _ }) ->
             Ok
               (List.map
                  (fun (entry : Yaml_json.field) ->
                    (entry.Yaml_json.name, Yaml_json.to_yojson entry.Yaml_json.value))
                  entries)
           | Some _ ->
             Error
               [ diagnostic TM401 path
                   "collection.read_defaults must be a mapping" ])))

let resolve_schema ~path ~root node =
  match field node "schema" with
  | None ->
    Error [ diagnostic TM401 path "a type file must declare a schema" ]
  | Some schema_node -> (
    (match Option.bind (field schema_node "dialect") text_of with
     | None | Some "json-schema-2020-12" -> Ok ()
     | Some other ->
       Error
         [ diagnostic TM401 path
             ("schema.dialect \"" ^ other ^ "\" is not json-schema-2020-12") ])
    |> Result.map (fun () -> ())
    |> function
    | Error diagnostics -> Error diagnostics
    | Ok () -> (
      match (field schema_node "value", field schema_node "ref") with
      | Some _, Some _ ->
        Error
          [ diagnostic TM401 path
              "a schema declares exactly one of `value` and `ref`, not both" ]
      | None, None ->
        Error
          [ diagnostic TM401 path
              "a schema declares one of `value` and `ref`" ]
      | Some value, None -> (
        match Json_schema.compile (Yaml_json.to_yojson value) with
        | Ok compiled -> Ok compiled
        | Error message -> Error [ diagnostic TM401 path message ])
      | None, Some reference -> (
        match text_of reference with
        | None -> Error [ diagnostic TM401 path "schema.ref must be a string" ]
        | Some relative -> (
          (* §06: the base URI is the directory holding the type file, and the
             resolved file must stay inside the collection. *)
          let base = Filename.dirname path in
          let candidate = Path_safe.normalize_absolute (Filename.concat base relative) in
          if not (Path_safe.is_within ~root candidate) then
            Error
              [ diagnostic ~mdbase_code:"schema_ref_forbidden" TM401 path
                  ("schema.ref \"" ^ relative
                   ^ "\" resolves outside the collection") ]
          else
            match In_channel.with_open_bin candidate In_channel.input_all with
            | exception Sys_error message ->
              Error
                [ diagnostic ~mdbase_code:"schema_ref_unresolved" TM401 path
                    ("cannot read schema.ref \"" ^ relative ^ "\": " ^ message) ]
            | contents -> (
              match Yojson.Safe.from_string contents with
              | exception _ ->
                Error
                  [ diagnostic TM401 path
                      ("schema.ref \"" ^ relative ^ "\" is not valid JSON") ]
              | json -> (
                match Json_schema.compile json with
                | Ok compiled -> Ok compiled
                | Error message -> Error [ diagnostic TM401 path message ]))))))

let parse_type_file ~root ~path contents =
  match Source.of_string ~path contents with
  | Error _ -> Error [ diagnostic TM401 path "type file is not valid UTF-8" ]
  | Ok source -> (
    match Frontmatter.parse source with
    | Error diagnostics ->
      Error
        (List.map
           (fun (d : Diagnostic.t) ->
             diagnostic TM401 path ("type file: " ^ d.Diagnostic.message))
           diagnostics)
    | Ok (parsed, _warnings) -> (
      match parsed.Frontmatter.frontmatter with
      | None -> Ok None
      | Some node -> (
        match Option.bind (field node "kind") text_of with
        | Some "mdbase.type" -> (
          let refused =
            List.find_map
              (fun (name, _) ->
                List.assoc_opt name unsupported_sections
                |> Option.map (fun why -> (name, why)))
              (Yaml_json.keys node)
          in
          match refused with
          | Some (section, why) ->
            Error
              [ diagnostic ~mdbase_code:"unsupported_profile" TM401 path
                  (section ^ " is not acted on by tree-md: " ^ why) ]
          | None -> (
            let unknown =
              List.find_opt
                (fun (name, _) ->
                  not (List.mem name supported_sections)
                  && not (String.length name >= 2 && String.sub name 0 2 = "x-"))
                (Yaml_json.keys node)
            in
            match unknown with
            | Some (section, _) ->
              Error
                [ diagnostic TM401 path
                    ("unknown type-file section \"" ^ section ^ "\"") ]
            | None -> (
              match Option.bind (field node "name") text_of with
              | None ->
                Error [ diagnostic TM401 path "a type file must declare a name" ]
              | Some name ->
                let* schema = resolve_schema ~path ~root node in
                let* path_globs, fields_present, where, has_match =
                  parse_match ~path (field node "match")
                in
                let* read_defaults =
                  parse_collection ~path (field node "collection")
                in
                Ok
                  (Some
                     { name; path; schema; path_globs; fields_present; where;
                       has_match; read_defaults }))))
        | _ -> Ok None)))

let rec discover ~dir acc =
  match Sys.readdir dir with
  | exception Sys_error _ -> acc
  | entries ->
    Array.sort String.compare entries;
    Array.fold_left
      (fun acc entry ->
        if String.length entry > 0 && entry.[0] = '.' then acc
        else
          let full = Filename.concat dir entry in
          match Unix.lstat full with
          | { Unix.st_kind = Unix.S_DIR; _ } -> discover ~dir:full acc
          | { Unix.st_kind = Unix.S_REG; _ }
            when Filename.check_suffix entry ".md" -> full :: acc
          | _ -> acc
          | exception Unix.Unix_error _ -> acc)
      acc entries

let load ~directory ~config =
  let folder = Filename.concat directory config.Mdbase_config.types_folder in
  if not (Sys.file_exists folder) then Ok ([], [])
  else
    let paths = List.rev (discover ~dir:folder []) in
    let rec loop types warnings = function
      | [] -> Ok (types, warnings)
      | path :: rest -> (
        match In_channel.with_open_bin path In_channel.input_all with
        | exception Sys_error message ->
          Error [ diagnostic TM401 path ("cannot read type file: " ^ message) ]
        | contents -> (
          match parse_type_file ~root:directory ~path contents with
          | Error diagnostics -> Error diagnostics
          | Ok None ->
            (* §02 permits warning about a file under the types folder that is
               not a type file. It is never treated as a record. *)
            loop types
              (warn TM401 path
                 "file under the types folder does not declare `kind: \
                  mdbase.type`; it is not loaded as a type and never read as a \
                  record"
               :: warnings)
              rest
          | Ok (Some declared) -> loop (declared :: types) warnings rest))
    in
    let* types, warnings = loop [] [] paths in
    (* §05: names are compared case-insensitively, and two that differ only by
       case are conflicting definitions. *)
    let sorted =
      List.sort
        (fun a b ->
          String.compare (String.lowercase_ascii a.name)
            (String.lowercase_ascii b.name))
        (List.rev types)
    in
    let rec duplicates = function
      | a :: (b :: _ as rest) ->
        if String.lowercase_ascii a.name = String.lowercase_ascii b.name then
          Error
            [ diagnostic
                ~secondary:[ { Diagnostic.label = "also defined here";
                               location = Span.Path a.path } ]
                TM401 b.path
                ("duplicate type name \"" ^ b.name ^ "\"") ]
        else duplicates rest
      | _ -> Ok ()
    in
    let* () = duplicates sorted in
    Ok (sorted, List.rev warnings)

(* ── selection (§07) ── *)

let json_field (frontmatter : Yojson.Safe.t) selector =
  (* Both forms §07 names: a field path, and a non-root JSON Pointer. *)
  let tokens =
    if String.length selector > 0 && selector.[0] = '/' then
      String.split_on_char '/' (String.sub selector 1 (String.length selector - 1))
      (* RFC 6901 escapes: `~1` is `/` and `~0` is `~`, decoded in that order. *)
      |> List.map (fun token ->
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
           Buffer.contents buf)
    else String.split_on_char '.' selector
  in
  List.fold_left
    (fun value token ->
      match value with
      | Some (`Assoc entries) -> List.assoc_opt token entries
      | _ -> None)
    (Some frontmatter) tokens

let compare_json a b =
  match (a, b) with
  | `Int x, `Int y -> Some (Int.compare x y)
  | (`Int _ | `Float _), (`Int _ | `Float _) ->
    let number = function `Int n -> float_of_int n | `Float f -> f | _ -> 0. in
    Some (Float.compare (number a) (number b))
  | `String x, `String y -> Some (String.compare x y)
  | _ -> None

let contains_value haystack needle =
  match (haystack, needle) with
  | `String s, `String sub ->
    let n = String.length sub in
    let rec loop i =
      i + n <= String.length s && (String.sub s i n = sub || loop (i + 1))
    in
    n = 0 || loop 0
  | `List items, _ -> List.mem needle items
  | _ -> false

let has_prefix s prefix =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let has_suffix s suffix =
  let n = String.length s and m = String.length suffix in
  n >= m && String.sub s (n - m) m = suffix

(* §07: except for `exists`, an operator is false when its field is missing or
   null, ordering is false for incomparable values, and an operand of the wrong
   type is false. *)
let predicate_holds value predicate =
  match predicate with
  | Exists wanted -> (value <> None) = wanted
  | _ -> (
    match value with
    | None | Some `Null -> false
    | Some actual -> (
      match predicate with
      | Exists _ -> false
      | Compare (Eq, expected) -> actual = expected
      | Compare (Neq, expected) -> actual <> expected
      | Compare (op, expected) -> (
        match compare_json actual expected with
        | None -> false
        | Some ordering -> (
          match op with
          | Gt -> ordering > 0
          | Gte -> ordering >= 0
          | Lt -> ordering < 0
          | Lte -> ordering <= 0
          | Eq | Neq -> false))
      | Contains needle -> contains_value actual needle
      | Contains_all needles ->
        List.for_all (contains_value actual) needles
      | Contains_any needles -> List.exists (contains_value actual) needles
      | Starts_with prefix -> (
        match actual with `String s -> has_prefix s prefix | _ -> false)
      | Ends_with suffix -> (
        match actual with `String s -> has_suffix s suffix | _ -> false)
      | Matches (_source, regex) -> (
        match actual with `String s -> Re.execp regex s | _ -> false)))

let matches declared ~collection_path ~frontmatter =
  declared.has_match
  && (declared.path_globs = []
      || List.exists
           (fun glob -> Path_safe.glob_matches ~pattern:glob collection_path)
           declared.path_globs)
  && List.for_all
       (fun selector ->
         match json_field frontmatter selector with
         | None | Some `Null -> false
         | Some _ -> true)
       declared.fields_present
  && List.for_all
       (fun (selector, predicates) ->
         let value = json_field frontmatter selector in
         List.for_all (predicate_holds value) predicates)
       declared.where

let select types ~config ~collection_path ~frontmatter =
  let declared_names =
    List.concat_map
      (fun key ->
        match json_field frontmatter key with
        | Some (`String s) -> [ s ]
        | Some (`List items) ->
          List.filter_map (function `String s -> Some s | _ -> None) items
        | _ -> [])
      config.Mdbase_config.explicit_type_keys
  in
  if declared_names <> [] then begin
    (* §07: the explicit branch completes type selection; inferred rules are
       skipped for that record. Order is declaration order, de-duplicated
       case-insensitively, keeping the first occurrence. *)
    let seen = Hashtbl.create 8 in
    let chosen, missing =
      List.fold_left
        (fun (chosen, missing) wanted ->
          let key = String.lowercase_ascii wanted in
          if Hashtbl.mem seen key then (chosen, missing)
          else begin
            Hashtbl.add seen key ();
            match
              List.find_opt
                (fun t -> String.lowercase_ascii t.name = key) types
            with
            | Some found -> (chosen @ [ found ], missing)
            | None -> (chosen, missing @ [ wanted ])
          end)
        ([], []) declared_names
    in
    ( chosen,
      List.map
        (fun wanted ->
          Diagnostic.warn TM401 Span.No_location
            ("front matter declares the type \"" ^ wanted
             ^ "\", which no type file defines"))
        missing )
  end
  else
    ( List.filter (fun t -> matches t ~collection_path ~frontmatter) types, [] )
