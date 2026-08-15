type source_file = {
  source_root : string;
  path : string;
  config_relative : Path_safe.relative;
  source_relative : Path_safe.relative;
  output_relative : Path_safe.relative;
  root_id : string;
}

type handwritten_root = { id : string; path : string }

type t = {
  sources : source_file list;
  handwritten_roots : handwritten_root list;
}

let ( let* ) = Result.bind

let diagnostic ?secondary code path message =
  Diagnostic.make ?secondary code (Span.Path path) message

let tm201 ?secondary path message = diagnostic ?secondary TM201 path message
let tm205 path message = diagnostic TM205 path message
let tm404 path message = diagnostic TM404 path message

let has_suffix ~suffix name =
  let name_length = String.length name in
  let suffix_length = String.length suffix in
  name_length >= suffix_length
  && String.sub name (name_length - suffix_length) suffix_length = suffix

let strip_suffix ~suffix name =
  String.sub name 0 (String.length name - String.length suffix)

let is_hidden name = String.length name > 0 && name.[0] = '.'

let has_hidden_component path =
  List.exists (fun component -> component.[0] = '.')
    (String.split_on_char '/' path)

let read_directory path =
  try
    let handle = Unix.opendir path in
    let entries = ref [] in
    (try
       while true do
         let name = Unix.readdir handle in
         if name <> "." && name <> ".." then entries := name :: !entries
       done
     with End_of_file -> ());
    Unix.closedir handle;
    Ok (List.sort String.compare !entries)
  with Unix.Unix_error (error, _, _) -> Error (Unix.error_message error)

(* Recursively discover every regular file whose name ends exactly in
   [suffix], without following symlinks or entering hidden paths. Each result
   is (path, relative-to-root, stem). Directory entries are sorted before
   descent so traversal is deterministic. *)
let rec discover_files ~dir_path ~dir_rel ~suffix acc =
  let entry_rel name =
    if dir_rel = "" then name else dir_rel ^ "/" ^ name
  in
  match read_directory dir_path with
  | Error message ->
    Error [ tm205 dir_path ("cannot read directory during scanning: " ^ message) ]
  | Ok entries ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | name :: rest ->
        if is_hidden name then loop acc rest
        else
          let entry_path = Filename.concat dir_path name in
          match Unix.lstat entry_path with
          | { Unix.st_kind = Unix.S_LNK; _ } -> loop acc rest
          | { Unix.st_kind = Unix.S_DIR; _ } ->
            if has_suffix ~suffix name then
              Error
                [ tm205 entry_path
                    ("expected a regular file, found a directory: " ^ name) ]
            else
              let* acc =
                discover_files ~dir_path:entry_path ~dir_rel:(entry_rel name) ~suffix acc
              in
              loop acc rest
          | { Unix.st_kind = Unix.S_REG; _ } ->
            if has_suffix ~suffix name then
              loop
                ((entry_path, entry_rel name, strip_suffix ~suffix name) :: acc)
                rest
            else loop acc rest
          | { Unix.st_kind = _; _ } -> loop acc rest
          | exception Unix.Unix_error (error, _, _) ->
            Error
              [ tm205 entry_path
                  ("path changed type during scanning: " ^ Unix.error_message error) ]
    in
    loop acc entries

let build_source_record root_rel root_abs (path, source_rel_string, stem) =
  match Path_safe.relative source_rel_string with
  | Error _ -> None
  | Ok source_relative ->
    let prefix = strip_suffix ~suffix:".tree.md" source_rel_string in
    (match Path_safe.relative (prefix ^ ".tree") with
     | Error _ -> None
     | Ok output_relative ->
       Some
         { source_root = root_abs;
           path;
           config_relative = Path_safe.append root_rel source_relative;
           source_relative;
           output_relative;
           root_id = stem })

let duplicate_identities diags entries =
  (* [entries] : (id * path) list sorted by id then path *)
  let rec loop diags = function
    | [] -> diags
    | (id, path) :: ((next_id, next_path) :: _ as rest) when id = next_id ->
      loop
        (tm201 ~secondary:[ { label = "first defined here"; location = Span.Path path } ]
           next_path ("duplicate root identity \"" ^ id ^ "\"")
         :: diags)
        rest
    | _ :: rest -> loop diags rest
  in
  loop diags entries

let source_identities records =
  List.map (fun record -> (record.root_id, record.path)) records

let collect_sources config =
  let fold (diags, records) (root_rel, root_abs) =
    if has_hidden_component (Path_safe.to_string root_rel) then (diags, records)
    else
      match Unix.lstat root_abs with
      | { Unix.st_kind = Unix.S_LNK; _ } ->
        (tm404 root_abs "source root is a symbolic link" :: diags, records)
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        (match
           discover_files ~dir_path:root_abs ~dir_rel:"" ~suffix:".tree.md" []
         with
         | Error more -> (more @ diags, records)
         | Ok found ->
           let invalid, valid =
             List.partition
               (fun (_, _, stem) -> not (Metadata.valid_id stem))
               found
           in
           let invalid_diags =
             List.map
               (fun (path, _, stem) ->
                 tm201 path ("invalid root identity \"" ^ stem ^ "\""))
               invalid
           in
           let root_records =
             List.filter_map (build_source_record root_rel root_abs) valid
           in
           (invalid_diags @ diags, root_records @ records))
      | { Unix.st_kind = _; _ } ->
        (tm404 root_abs "source root is not a directory" :: diags, records)
      | exception Unix.Unix_error (error, _, _) ->
        (tm404 root_abs
           ("cannot scan source root: " ^ Unix.error_message error)
         :: diags, records)
  in
  let diags, records = List.fold_left fold ([], []) config.Config.source_roots in
  let records =
    List.sort
      (fun a b ->
        let by_identity = String.compare a.root_id b.root_id in
        if by_identity <> 0 then by_identity else String.compare a.path b.path)
      records
  in
  let diags = duplicate_identities diags (source_identities records) in
  (diags, records)

let handwritten_identities records =
  List.map (fun record -> (record.id, record.path)) records

let collect_handwritten config =
  let generated_root = snd config.Config.output_root in
  let fold (diags, records) (root_rel, root_abs) =
    if root_abs = generated_root then (diags, records)
    else if has_hidden_component (Path_safe.to_string root_rel) then
      (diags, records)
    else
      match Unix.lstat root_abs with
      | { Unix.st_kind = Unix.S_LNK; _ } ->
        (tm404 root_abs "tree root is a symbolic link" :: diags, records)
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        (match discover_files ~dir_path:root_abs ~dir_rel:"" ~suffix:".tree" [] with
         | Error more -> (more @ diags, records)
         | Ok found ->
           let invalid, valid =
             List.partition
               (fun (_, _, stem) -> not (Metadata.valid_id stem))
               found
           in
           let invalid_diags =
             List.map
               (fun (path, _, stem) ->
                 tm201 path ("invalid root identity \"" ^ stem ^ "\""))
               invalid
           in
           let root_records =
             List.map (fun (path, _, stem) -> { id = stem; path }) valid
           in
           (invalid_diags @ diags, root_records @ records))
      | { Unix.st_kind = _; _ } ->
        (tm404 root_abs "tree root is not a directory" :: diags, records)
      | exception Unix.Unix_error (error, _, _) ->
        (tm404 root_abs
           ("cannot scan tree root: " ^ Unix.error_message error)
         :: diags, records)
  in
  let diags, records =
    List.fold_left fold ([], []) config.Config.forest.Config.tree_roots
  in
  let records =
    List.sort
      (fun a b ->
        let by_identity = String.compare a.id b.id in
        if by_identity <> 0 then by_identity else String.compare a.path b.path)
      records
  in
  let diags = duplicate_identities diags (handwritten_identities records) in
  (diags, records)

let scan config =
  let sources_diags, sources = collect_sources config in
  let handwritten_diags, handwritten = collect_handwritten config in
  let diagnostics =
    List.sort Diagnostic.compare (sources_diags @ handwritten_diags)
  in
  if diagnostics <> [] then Error diagnostics
  else Ok { sources; handwritten_roots = handwritten }

let asset_matches forest relative =
  let path = Path_safe.to_string relative in
  if has_hidden_component path then []
  else
    List.filter_map
      (fun (_, base) ->
        let candidate = Path_safe.resolve ~base relative in
        match Unix.lstat candidate with
        | { Unix.st_kind = Unix.S_REG; _ } -> Some candidate
        | _ -> None
        | exception Unix.Unix_error _ -> None)
      forest.Config.asset_roots
