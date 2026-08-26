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

let assemble ~tolerant ~handwritten ~generated =
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
        (* A tolerant index keeps the first definition so that the pass which
           only needs to know where a reference lands can still run. Two
           private notes sharing an address must not stop the site from
           working out what is public. *)
        let index = if tolerant then StringMap.add id first index else index in
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
  if tolerant || diags = [] then Ok { by_id = index; by_filename; all_files }
  else Error (List.sort Diagnostic.compare diags)

let build ~handwritten ~generated =
  assemble ~tolerant:false ~handwritten ~generated

(* An index that keeps going when two trees share an identity. Only the pass
   that works out which trees are published uses it: that pass runs before
   anything is reported, and two notes nobody publishes must not stop it. *)
let build_tolerant ~handwritten ~generated =
  match assemble ~tolerant:true ~handwritten ~generated with
  | Ok index -> index
  | Error _ -> { by_id = StringMap.empty; by_filename = StringMap.empty; all_files = [] }

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

(* The identity a reference lands on, without asking which file owns it: when
   two trees share an address the owner is exactly what is not yet settled, and
   the pass that walks the reference graph must pull in both so that the
   duplicate is reported rather than silently picked between. *)
let resolve_reference index ~from target =
  match resolve_target index ~from target with
  | None -> None
  | Some (id, _ambiguous) -> Some id

(* The file a name would land in if the index has not heard of it: an editor
   writes file names, and a source that failed to parse contributes no
   identity, so without this a note that is broken looks merely absent. *)
let source_of_filename sources target =
  let candidates = spellings target in
  List.find_map
    (fun spelling ->
      List.find_opt
        (fun (record : Discovery.source_file) ->
          String.equal record.Discovery.filename spelling
          || String.equal
               (Path_safe.to_string record.Discovery.source_relative)
               (spelling ^ ".tree.md"))
        sources
      |> Option.map (fun (record : Discovery.source_file) -> record.Discovery.path))
    candidates

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

(* What `[assets].into` names is an output directory that happens to sit
   under an asset root, so what is in it is this build's own work rather than
   an asset the forest keeps. Searching it would make a build depend on
   whether the last one ran: the copy would be found where it was put, the
   attachment would no longer need copying, and the next build would delete
   what the one after it created. *)
let is_published_copy ~into candidate =
  match into with
  | None -> false
  | Some (into : Config.attachments) ->
    Path_safe.is_within ~root:into.Config.directory candidate

(* Obsidian embeds an attachment by its file name, wherever it lives in the
   vault: `![[diagram.png]]`, not `![[assets/images/diagram.png]]`. A name that
   carries no separator is therefore searched for under the asset roots. Built
   once per resolve, because it walks them. *)
let attachments_by_name ~into (forest : Config.forest) =
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
            | { Unix.st_kind = Unix.S_DIR; _ } ->
              if is_published_copy ~into path then ()
              else walk ~rel_root ~root_abs ~rel_dir:rel
            | { Unix.st_kind = Unix.S_REG; _ }
              when not (is_published_copy ~into path) ->
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

(* A file the vault keeps beside its notes, which a published tree embedded.
   The copy is what puts it under an asset root: that is where Forester plants
   an asset, and a route can name nowhere else. *)
type attachment_copy = {
  attachment : Discovery.attachment;
  destination : Path_safe.relative;
}

(* Obsidian writes a bare file name for an attachment and a path when it was
   told to spell one out, so both are answered: a name is searched for by
   name, a path by the path it was written as, below each source root. *)
let attachment_index (records : Discovery.attachment list) =
  let by_name = Hashtbl.create 64 and by_path = Hashtbl.create 64 in
  List.iter
    (fun (record : Discovery.attachment) ->
      let add table key =
        Hashtbl.replace table key
          (Option.value ~default:[] (Hashtbl.find_opt table key) @ [ record ])
      in
      add by_name record.Discovery.name;
      add by_path (Path_safe.to_string record.Discovery.source_relative))
    records;
  (by_name, by_path)

let attachment_matches (by_name, by_path) destination =
  let table = if String.contains destination '/' then by_path else by_name in
  Option.value ~default:[] (Hashtbl.find_opt table destination)

let check_asset ~into ~attachments ~sources ~claimed ~forest_asset_roots
    (diags, resolution, copies)
    (asset : Parsed_document.local_asset) =
  let destination = asset.destination in
  let location = Span.Source_span asset.span in
  let error code message =
    (Diagnostic.make code location message :: diags, resolution, copies)
  in
  let route routed =
    (diags, Resolution.add_asset asset.span ~routed_path:routed resolution,
     copies)
  in
  (* An attachment the vault keeps beside its notes: found under a source
     root, published by being copied to where `[assets].into` says. Without
     that table nothing is copied anywhere, so the file is still missing from
     the forest — but saying only that would send the writer looking for a
     file that is sitting right there. *)
  let publish (record : Discovery.attachment) =
    match into with
    | None ->
      (Diagnostic.make TM203 location ("missing asset \"" ^ destination ^ "\"")
         ~notes:
           [ "the vault keeps it at "
             ^ Path_safe.to_string record.Discovery.config_relative
             ^ ", which is not under an asset root; `[assets].into` in \
                tree-md.toml says where an attachment a published tree \
                embeds is copied to" ]
       :: diags, resolution, copies)
    | Some (into : Config.attachments) ->
      let destination_path =
        Path_safe.append into.Config.config_relative
          record.Discovery.source_relative
      in
      let routed =
        into.Config.route_prefix ^ "/"
        ^ Path_safe.to_string record.Discovery.source_relative
      in
      let key = Path_safe.to_string destination_path in
      (match Hashtbl.find_opt claimed key with
       | Some (other : Discovery.attachment)
         when other.Discovery.path <> record.Discovery.path ->
         (* Two source roots holding the same relative path would be copied
            onto one file, and whichever was written second would win. *)
         error TM204
           ("ambiguous asset \"" ^ destination ^ "\": "
            ^ Path_safe.to_string record.Discovery.config_relative ^ " and "
            ^ Path_safe.to_string other.Discovery.config_relative
            ^ " are both published at " ^ key)
       | Some _ -> route routed
       | None ->
         Hashtbl.replace claimed key record;
         (diags,
          Resolution.add_asset asset.span ~routed_path:routed resolution,
          { attachment = record; destination = destination_path } :: copies))
  in
  let from_sources () =
    match attachment_matches sources destination with
    | [ record ] -> publish record
    | _ :: _ :: _ as found ->
      error TM204
        ("ambiguous asset \"" ^ destination ^ "\" (matches "
         ^ string_of_int (List.length found)
         ^ " files under the source roots); write the path to say which one \
            you mean")
    | [] -> error TM203 ("missing asset \"" ^ destination ^ "\"")
  in
  match Path_safe.relative destination with
  | Error message ->
    error TM205 ("unsafe asset path \"" ^ destination ^ "\": " ^ message)
  | Ok relative ->
    if has_hidden_component destination then
      error TM205
        ("unsafe asset path \"" ^ destination ^ "\" (hidden path component)")
    else
      let unsafe, matches =
        List.fold_left
          (fun (unsafe, matches) (rel_root, abs_root) ->
            if is_published_copy ~into (Path_safe.resolve ~base:abs_root relative)
            then (unsafe, matches)
            else
            match resolve_asset_root ~root_abs:abs_root relative with
            | Asset_regular -> (unsafe, rel_root :: matches)
            | Asset_unsafe reason -> (reason :: unsafe, matches)
            | Asset_missing -> (unsafe, matches))
          ([], []) forest_asset_roots
      in
      if unsafe <> [] then
        let reasons = String.concat "; " (List.rev unsafe) in
        error TM205
          ("unsafe asset path \"" ^ destination ^ "\" (" ^ reasons ^ ")")
      else
        match List.rev matches with
        | [] when not (String.contains destination '/') -> (
          (* A bare file name is what Obsidian writes for an attachment. An
             asset root answers first: a file already kept where the forest
             keeps its assets is published where it lies, and needs no copy. *)
          match Hashtbl.find_opt (Lazy.force attachments) destination with
          | Some [ (rel_root, relative_path) ] ->
            route (rel_root ^ "/" ^ relative_path)
          | Some (_ :: _ :: _ as found) ->
            error TM204
              ("ambiguous asset \"" ^ destination ^ "\" (matches "
               ^ string_of_int (List.length found) ^ " files under the asset \
                  roots); write the path to say which one you mean")
          | Some [] | None -> from_sources ())
        | [] -> from_sources ()
        | [ rel_root ] ->
          route (Path_safe.to_string rel_root ^ "/" ^ destination)
        | _ ->
          error TM204
            ("ambiguous asset \"" ^ destination
             ^ "\" (matches multiple asset roots)")

(* Warnings ride along with the resolutions; only an error discards them. *)
let resolve ?(attachments = []) ?into forest index ~documents =
  let by_name = lazy (attachments_by_name ~into forest) in
  let sources = attachment_index attachments in
  let claimed = Hashtbl.create 16 in
  let diags, copies, results =
    List.fold_left (fun (diags, copies, results) (doc : Parsed_document.t) ->
      let diags, resolution =
        check_references index doc (diags, Resolution.empty)
      in
      let diags, resolution, copies =
        List.fold_left
          (check_asset ~into ~attachments:by_name ~sources ~claimed
             ~forest_asset_roots:forest.Config.asset_roots)
          (diags, resolution, copies)
          doc.Parsed_document.local_assets
      in
      (diags, copies,
       (doc.Parsed_document.outline.Outline.root_id, resolution) :: results)
    ) ([], [], []) documents
  in
  Diagnostic.gate
    (List.rev results, List.rev copies)
    (List.sort Diagnostic.compare diags)
