module StringMap = Map.Make(String)

type definition_kind = Generated_root | Generated_subtree | Handwritten_root

type definition = {
  id : string;
  kind : definition_kind;
  location : Span.location;
}

type t = definition StringMap.t

(* ── Location ordering (path, rank, byte), mirroring Diagnostic.compare ── *)

let location_path = function
  | Span.Source_span span -> Some span.Span.path
  | Span.Path path -> Some path
  | Span.No_location -> None

let location_rank = function
  | Span.Source_span _ -> 0
  | Span.Path _ -> 1
  | Span.No_location -> 2

let location_byte = function
  | Span.Source_span span -> Some span.Span.start_byte
  | Span.Path _ | Span.No_location -> None

let compare_locations (a : Span.location) (b : Span.location) =
  let by_path =
    match location_path a, location_path b with
    | None, None -> 0
    | None, Some _ -> 1
    | Some _, None -> -1
    | Some first, Some second -> String.compare first second
  in
  if by_path <> 0 then by_path
  else
    let by_rank = Int.compare (location_rank a) (location_rank b) in
    if by_rank <> 0 then by_rank
    else
      match location_byte a, location_byte b with
      | None, None -> 0
      | None, Some _ -> 1
      | Some _, None -> -1
      | Some first, Some second -> Int.compare first second

let compare_definitions (a : definition) (b : definition) =
  compare_locations a.location b.location

(* ── build: one global identity index ── *)

let generated_definitions (doc : Parsed_document.t) : definition list =
  let root =
    { id = doc.Parsed_document.outline.Outline.root_id;
      kind = Generated_root;
      location = Span.Source_span doc.Parsed_document.outline.Outline.span }
  in
  let subtrees =
    List.map
      (fun (outline_def : Outline.definition) ->
        { id = outline_def.Outline.id;
          kind = Generated_subtree;
          location = Span.Source_span outline_def.Outline.span })
      doc.Parsed_document.definitions
  in
  root :: subtrees

let handwritten_definitions (handwritten : Discovery.handwritten_root list)
    : definition list =
  List.map
    (fun root ->
      { id = root.Discovery.id;
        kind = Handwritten_root;
        location = Span.Path root.Discovery.path })
    handwritten

let build ~handwritten ~generated =
  let all =
    handwritten_definitions handwritten
    @ List.concat_map generated_definitions generated
  in
  let grouped =
    List.fold_left (fun table (def : definition) ->
      let existing =
        match StringMap.find_opt def.id table with
        | Some definitions -> definitions
        | None -> []
      in
      StringMap.add def.id (def :: existing) table
    ) StringMap.empty all
  in
  let diags, index =
    StringMap.fold (fun id definitions (diags, index) ->
      match List.sort compare_definitions definitions with
      | [ single ] -> (diags, StringMap.add id single index)
      | first :: later ->
        let secondary =
          List.map
            (fun (def : definition) ->
              { Diagnostic.label = "also defined here";
                location = def.location })
            later
        in
        let diagnostic =
          Diagnostic.make ~secondary TM201 first.location
            ("duplicate identity \"" ^ id ^ "\"")
        in
        (diagnostic :: diags, index)
      | [] -> (diags, index)
    ) grouped ([], StringMap.empty)
  in
  if diags = [] then Ok index
  else Error (List.sort Diagnostic.compare diags)

(* ── resolve: reference and asset validation per document ── *)

let reference_kind_message = function
  | Ir.Wiki -> "wiki link"
  | Ir.Embed -> "embed"
  | Ir.Attribution -> "attribution"

let tree_suffix = ".tree"

let strip_tree_suffix target =
  let n = String.length target in
  let s = String.length tree_suffix in
  if n > s && String.sub target (n - s) s = tree_suffix then
    Some (String.sub target 0 (n - s))
  else
    None

(* A tree written as `foo.tree.md` has the identity `foo`, but an editor that
   addresses notes by filename sees `foo.tree` and writes `[[foo.tree]]`. Accept
   that spelling by retrying a miss with the suffix removed. The exact match is
   tried first, so a tree whose identity really is `foo.tree` still wins. *)
let resolve_target index target =
  if StringMap.mem target index then Some target
  else
    match strip_tree_suffix target with
    | Some stripped when StringMap.mem stripped index -> Some stripped
    | Some _ | None -> None

let check_references index (doc : Parsed_document.t) (diags, resolution) =
  List.fold_left (fun (diags, resolution) (reference : Ir.reference) ->
    match resolve_target index reference.target with
    | Some id when String.equal id reference.target -> (diags, resolution)
    | Some id ->
      (diags, Resolution.add_tree reference.span ~id resolution)
    | None ->
      let kind = reference_kind_message reference.kind in
      (Diagnostic.make TM202 (Span.Source_span reference.span)
         ("unresolved " ^ kind ^ " \"" ^ reference.target ^ "\"")
       :: diags,
       resolution)
  ) (diags, resolution) doc.Parsed_document.references

let has_hidden_component path =
  List.exists (fun component ->
    String.length component > 0 && component.[0] = '.')
    (String.split_on_char '/' path)

type asset_outcome =
  | Asset_missing
  | Asset_regular
  | Asset_unsafe of string

let realpath path =
  try Ok (Unix.realpath path) with Unix.Unix_error _ -> Error ()

let regular_within_root ~root candidate =
  match realpath candidate with
  | Error () -> Asset_unsafe "cannot resolve real path"
  | Ok real_candidate ->
    let contained =
      match realpath root with
      | Ok real_root -> Path_safe.is_within ~root:real_root real_candidate
      | Error () -> Path_safe.is_within ~root real_candidate
    in
    if contained then Asset_regular
    else Asset_unsafe "symbolic link escapes asset root"

let resolve_asset_root ~root_abs relative =
  let candidate = Path_safe.resolve ~base:root_abs relative in
  match Unix.lstat candidate with
  | { Unix.st_kind = Unix.S_REG; _ } ->
    regular_within_root ~root:root_abs candidate
  | { Unix.st_kind = Unix.S_LNK; _ } ->
    Asset_unsafe "asset is a symbolic link"
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Asset_unsafe "expected a regular file, found a directory"
  | { Unix.st_kind = _; _ } -> Asset_missing
  | exception Unix.Unix_error _ -> Asset_missing

let check_asset forest (diags, resolution)
    (asset : Parsed_document.local_asset) =
  let destination = asset.destination in
  let location = Span.Source_span asset.span in
  match Path_safe.relative destination with
  | Error message ->
    (Diagnostic.make TM205 location
       ("unsafe asset path \"" ^ destination ^ "\": " ^ message)
     :: diags, resolution)
  | Ok relative ->
    if has_hidden_component destination then
      (Diagnostic.make TM205 location
         ("unsafe asset path \"" ^ destination ^ "\" (hidden path component)")
       :: diags, resolution)
    else
      let unsafe, matches =
        List.fold_left
          (fun (unsafe, matches) (rel_root, abs_root) ->
            match resolve_asset_root ~root_abs:abs_root relative with
            | Asset_regular -> (unsafe, rel_root :: matches)
            | Asset_unsafe reason -> (reason :: unsafe, matches)
            | Asset_missing -> (unsafe, matches))
          ([], []) forest.Config.asset_roots
      in
      if unsafe <> [] then
        let reasons = String.concat "; " (List.rev unsafe) in
        (Diagnostic.make TM205 location
           ("unsafe asset path \"" ^ destination ^ "\" (" ^ reasons ^ ")")
         :: diags, resolution)
      else
        match List.rev matches with
        | [] ->
          (Diagnostic.make TM203 location
             ("missing asset \"" ^ destination ^ "\"")
           :: diags, resolution)
        | [ rel_root ] ->
          let routed = Path_safe.to_string rel_root ^ "/" ^ destination in
          (diags, Resolution.add_asset asset.span ~routed_path:routed resolution)
        | _ ->
          (Diagnostic.make TM204 location
             ("ambiguous asset \"" ^ destination
              ^ "\" (matches multiple asset roots)")
           :: diags, resolution)

let resolve forest index ~documents =
  let diags, results =
    List.fold_left (fun (diags, results) (doc : Parsed_document.t) ->
      let diags, resolution =
        check_references index doc (diags, Resolution.empty)
      in
      let diags, resolution =
        List.fold_left (check_asset forest) (diags, resolution)
          doc.Parsed_document.local_assets
      in
      (diags,
       (doc.Parsed_document.outline.Outline.root_id, resolution) :: results)
    ) ([], []) documents
  in
  if diags = [] then Ok (List.rev results)
  else Error (List.sort Diagnostic.compare diags)
