module StringMap = Map.Make(String)

type definition_kind = Generated_root | Generated_subtree | Handwritten_root

type definition = {
  id : string;
  kind : definition_kind;
  location : Span.location;
}

(* One source file, as something a reference can name. [source] is its
   absolute path, [dir] the directory holding it, and [id] the tree it is. *)
type filed = { source : string; dir : string; id : string }

type t = {
  by_id : definition StringMap.t;
  (* An editor addresses notes by file name, so a reference written the way
     Obsidian writes it names the file rather than the tree. Held apart from
     the identities, and consulted only after them, so that an id always wins
     over a file that happens to be called the same thing.

     A stem can name more than one file — two folders may each hold a
     note.tree.md — so this maps to every candidate and resolution picks. *)
  by_filename : filed list StringMap.t;
  (* Every source, for `[[folder/note]]`: a wikilink containing a separator is
     resolved path-style rather than by stem. *)
  all_files : filed list;
}

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

(* `a/note.tree.md` -> `note`. The identity may be something else entirely;
   this is only the name an editor would write. *)
let source_stem (location : Span.location) =
  match location with
  | Span.Source_span span -> (
    let path = span.Span.path in
    let base =
      match String.rindex_opt path '/' with
      | None -> path
      | Some i -> String.sub path (i + 1) (String.length path - i - 1)
    in
    let suffix = ".tree.md" in
    let n = String.length base and m = String.length suffix in
    if n > m && String.sub base (n - m) m = suffix then
      Some (String.sub base 0 (n - m))
    else None)
  | Span.Path _ | Span.No_location -> None

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
  let all_files =
    List.filter_map
      (fun (doc : Parsed_document.t) ->
        let outline = doc.Parsed_document.outline in
        let source = outline.Outline.span.Span.path in
        match source_stem (Span.Source_span outline.Outline.span) with
        | Some _ ->
          let dir =
            match String.rindex_opt source '/' with
            | None -> ""
            | Some i -> String.sub source 0 i
          in
          Some { source; dir; id = outline.Outline.root_id }
        | None -> None)
      generated
  in
  let by_filename =
    List.fold_left
      (fun table (doc : Parsed_document.t) ->
        let outline = doc.Parsed_document.outline in
        let source = outline.Outline.span.Span.path in
        match source_stem (Span.Source_span outline.Outline.span) with
        | None -> table
        | Some stem ->
          let entry =
            List.find_opt (fun f -> f.source = source) all_files
          in
          (match entry with
           | None -> table
           | Some entry ->
             let existing =
               Option.value ~default:[] (StringMap.find_opt stem table)
             in
             StringMap.add stem (entry :: existing) table))
      StringMap.empty generated
  in
  if diags = [] then Ok { by_id = index; by_filename; all_files }
  else Error (List.sort Diagnostic.compare diags)

(* ── resolve: reference and asset validation per document ── *)

let reference_kind_message = function
  | Ir.Wiki -> "wiki link"
  | Ir.Embed -> "embed"
  | Ir.Attribution -> "attribution"
  | Ir.Markdown_link -> "link"

let tree_suffix = ".tree"

let strip_tree_suffix target =
  let n = String.length target in
  let s = String.length tree_suffix in
  if n > s && String.sub target (n - s) s = tree_suffix then
    Some (String.sub target 0 (n - s))
  else
    None

let md_suffix = ".md"

let strip_suffix suffix target =
  let n = String.length target in
  let s = String.length suffix in
  if n > s && String.sub target (n - s) s = suffix then
    Some (String.sub target 0 (n - s))
  else
    None

let strip_tree_suffix target = strip_suffix tree_suffix target

(* The spellings one target may be written as, most exact first.

   An editor shows `foo.tree.md` as `foo.tree` and writes `[[foo.tree]]`, and
   sometimes writes the whole file name. Stripping is cumulative so
   `[[foo.tree.md]]`, `[[foo.tree]]` and `[[foo]]` all reach `foo`. The
   written spelling is always tried before any stripped one, so a tree whose
   identity genuinely is `foo.tree` is never shadowed. *)
let spellings target =
  let add value acc = if List.mem value acc then acc else acc @ [ value ] in
  let acc = [ target ] in
  let acc =
    match strip_suffix md_suffix target with
    | None -> acc
    | Some without_md -> (
      let acc = add without_md acc in
      match strip_tree_suffix without_md with
      | None -> acc
      | Some bare -> add bare acc)
  in
  match strip_tree_suffix target with
  | None -> acc
  | Some bare -> add bare acc

let dirname path =
  match String.rindex_opt path '/' with
  | None -> ""
  | Some i -> String.sub path 0 i

(* A stem may name several files. mdbase v0.3 §08 fixes the order to try:
   the referring file's own folder first, then the shortest path, then
   alphabetical — so the answer does not depend on filesystem order. *)
let pick_file ~from candidates =
  match candidates with
  | [] -> None
  | [ only ] -> Some (only, false)
  | many ->
    let here = dirname from in
    let same_folder = List.filter (fun f -> f.dir = here) many in
    let pool, settled_by_folder =
      match same_folder with
      | [ one ] -> ([ one ], true)
      | [] -> (many, false)
      | several -> (several, false)
    in
    let ordered =
      List.sort
        (fun a b ->
          let by_length =
            Int.compare (String.length a.source) (String.length b.source)
          in
          if by_length <> 0 then by_length
          else String.compare a.source b.source)
        pool
    in
    (match ordered with
     | best :: _ -> Some (best, not settled_by_folder)
     | [] -> None)

(* Identity first, then file name, then path. An identity always wins: a tree
   that states its own `id` is no longer called after its file, but
   `[[the-file-name]]` is still what Obsidian writes and autocompletes, so the
   file name stays the search key. Returns the resolved identity and whether
   more than one file answered to the name. *)
let resolve_target index ~from target =
  let by_id = index.by_id in
  let candidates = spellings target in
  let as_identity =
    List.find_opt (fun spelling -> StringMap.mem spelling by_id) candidates
  in
  match as_identity with
  | Some id -> Some (id, false)
  | None ->
    let by_name =
      List.find_map
        (fun spelling ->
          match StringMap.find_opt spelling index.by_filename with
          | None | Some [] -> None
          | Some files -> pick_file ~from files)
        candidates
    in
    (match by_name with
     | Some (file, ambiguous) when StringMap.mem file.id by_id ->
       Some (file.id, ambiguous)
     | Some _ -> None
     | None ->
       (* `[[folder/note]]`: a target carrying a separator names a path. *)
       if not (String.contains target '/') then None
       else
         (* A written path may be relative to the referring file, so leading
            `./` and `../` are dropped before matching by suffix. *)
         let rec strip_relative value =
           if String.length value >= 2 && String.sub value 0 2 = "./" then
             strip_relative (String.sub value 2 (String.length value - 2))
           else if String.length value >= 3 && String.sub value 0 3 = "../" then
             strip_relative (String.sub value 3 (String.length value - 3))
           else value
         in
         let matches spelling file =
           let suffix = "/" ^ strip_relative spelling ^ ".tree.md" in
           let n = String.length file.source and s = String.length suffix in
           n > s && String.sub file.source (n - s) s = suffix
         in
         let by_path =
           List.find_map
             (fun spelling ->
               match List.filter (matches spelling) index.all_files with
               | [] -> None
               | files -> pick_file ~from files)
             candidates
         in
         (match by_path with
          | Some (file, ambiguous) when StringMap.mem file.id by_id ->
            Some (file.id, ambiguous)
          | Some _ | None -> None))

let check_references index (doc : Parsed_document.t) (diags, resolution) =
  let from = doc.Parsed_document.outline.Outline.span.Span.path in
  List.fold_left (fun (diags, resolution) (reference : Ir.reference) ->
    (* Picking one of several files with the same name is a decision the
       writer did not make, so it is said out loud rather than assumed. *)
    let ambiguity_warning ambiguous =
      if not ambiguous then []
      else
        [ Diagnostic.warn TM202 (Span.Source_span reference.span)
            ("\"" ^ reference.target
             ^ "\" names more than one file; resolved by mdbase link order \
                (nearest folder, then shortest path). Give the tree an `id:` \
                and reference that to say which one you mean") ]
    in
    match resolve_target index ~from reference.target with
    | Some (id, ambiguous) when String.equal id reference.target ->
      (ambiguity_warning ambiguous @ diags, resolution)
    | Some (id, ambiguous) ->
      (ambiguity_warning ambiguous @ diags,
       Resolution.add_tree reference.span ~id resolution)
    | None -> (
      let kind = reference_kind_message reference.kind in
      match reference.kind with
      | Ir.Markdown_link ->
        (* Only a wiki link is closed-world. A Markdown link was never checked
           at all before, and a local destination may be a relative URL to
           something the forest does not own, so one that does not resolve is
           left exactly as written. A destination ending in `.md` can only have
           meant a note, so that one is said out loud. *)
        if strip_suffix md_suffix reference.target = None then (diags, resolution)
        else
          (Diagnostic.warn TM202 (Span.Source_span reference.span)
             ("unresolved " ^ kind ^ " \"" ^ reference.target
              ^ "\"; it is emitted as written, which names no tree")
           :: diags,
           resolution)
      | Ir.Wiki | Ir.Embed | Ir.Attribution ->
        (Diagnostic.make TM202 (Span.Source_span reference.span)
           ("unresolved " ^ kind ^ " \"" ^ reference.target ^ "\"")
         :: diags,
         resolution))
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

(* Obsidian embeds an attachment by its file name, wherever it lives in the
   vault: `![[diagram.png]]`, not `![[assets/images/diagram.png]]`. A name that
   carries no separator is therefore searched for under the asset roots. Built
   once per resolve, because it walks them. *)
let attachments_by_name (forest : Config.forest) =
  let table = Hashtbl.create 64 in
  let rec walk ~rel_root ~root_abs ~rel_dir =
    let dir = if rel_dir = "" then root_abs else Filename.concat root_abs rel_dir in
    match Sys.readdir dir with
    | exception Sys_error _ -> ()
    | entries ->
      Array.sort String.compare entries;
      Array.iter
        (fun name ->
          if String.length name > 0 && name.[0] <> '.' then
            let rel = if rel_dir = "" then name else rel_dir ^ "/" ^ name in
            let path = Filename.concat root_abs rel in
            match Unix.lstat path with
            | { Unix.st_kind = Unix.S_DIR; _ } -> walk ~rel_root ~root_abs ~rel_dir:rel
            | { Unix.st_kind = Unix.S_REG; _ } ->
              let existing = Option.value ~default:[] (Hashtbl.find_opt table name) in
              Hashtbl.replace table name (existing @ [ (rel_root, rel) ])
            (* A symlink is skipped here for the same reason resolve_asset_root
               refuses one: it can leave the root. *)
            | _ -> ()
            | exception Unix.Unix_error _ -> ())
        entries
  in
  List.iter
    (fun (rel_root, root_abs) ->
      walk ~rel_root:(Path_safe.to_string rel_root) ~root_abs ~rel_dir:"")
    forest.Config.asset_roots;
  table

let check_asset forest ~attachments (diags, resolution)
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
        | [] when not (String.contains destination '/') -> (
          (* A bare file name is what Obsidian writes for an attachment. *)
          match Hashtbl.find_opt (Lazy.force attachments) destination with
          | Some [ (rel_root, relative_path) ] ->
            let routed = rel_root ^ "/" ^ relative_path in
            (diags, Resolution.add_asset asset.span ~routed_path:routed resolution)
          | Some (_ :: _ :: _ as found) ->
            (Diagnostic.make TM204 location
               ("ambiguous asset \"" ^ destination ^ "\" (matches "
                ^ string_of_int (List.length found) ^ " files under the asset \
                   roots); write the path to say which one you mean")
             :: diags, resolution)
          | Some [] | None ->
            (Diagnostic.make TM203 location
               ("missing asset \"" ^ destination ^ "\"")
             :: diags, resolution))
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

(* Warnings ride along with the resolutions; only an error discards them. *)
let resolve forest index ~documents =
  let attachments = lazy (attachments_by_name forest) in
  let diags, results =
    List.fold_left (fun (diags, results) (doc : Parsed_document.t) ->
      let diags, resolution =
        check_references index doc (diags, Resolution.empty)
      in
      let diags, resolution =
        List.fold_left (check_asset forest ~attachments) (diags, resolution)
          doc.Parsed_document.local_assets
      in
      (diags,
       (doc.Parsed_document.outline.Outline.root_id, resolution) :: results)
    ) ([], []) documents
  in
  Diagnostic.gate (List.rev results) (List.sort Diagnostic.compare diags)
