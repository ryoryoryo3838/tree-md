type 'a located = { value : 'a; span : Span.t }
type attribution = Tree of string located | Literal of string located

type raw = {
  (* Compile-time only: the tree's identity, which Forester takes from the
     file name of the .tree. Never emitted. *)
  id : string located option;
  date : string located option;
  taxon : string located option;
  authors : attribution list;
  contributors : attribution list;
  tags : string located list;
  meta : (string located * string located) list;
}

type 'inline t = {
  date : string located option;
  taxon : string located option;
  authors : attribution list;
  contributors : attribution list;
  tags : 'inline located list;
  meta : (string located * 'inline located) list;
}

let empty = ({
  id = None;
  date = None;
  taxon = None;
  authors = [];
  contributors = [];
  tags = [];
  meta = [];
} : raw)

let valid_id s =
  let len = String.length s in
  if len = 0 then false
  else
    let first = s.[0] in
    if not ((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z') || (first >= '0' && first <= '9'))
    then false
    else
      let rec loop i =
        if i >= len then true
        else
          let c = s.[i] in
          match c with
          | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> loop (i + 1)
          | _ -> false
      in
      loop 1

let valid_link_target s =
  s <> ""
  && String.for_all
       (fun c ->
         match c with
         | '[' | ']' | '|' | '#' | '^' -> false
         (* tree-md does not unescape a wiki body, so a backslash left in a
            target is either an escape that should have been consumed or a
            separator that is not supported either way. *)
         | '\\' -> false
         | c -> Char.code c >= 0x20 && Char.code c <> 0x7f)
       s

let parse_attribution located =
  let s = located.value in
  let len = String.length s in
  if len >= 4 && s.[0] = '[' && s.[1] = '['
     && s.[len - 2] = ']' && s.[len - 1] = ']'
  then
    let inner = String.sub s 2 (len - 4) in
    if valid_id inner then
      let inner_located = { value = inner; span = located.span } in
      Ok (Tree inner_located)
    else
      let diag =
        Diagnostic.make TM101
          (Span.Source_span located.span)
          ("invalid tree id: \"" ^ inner ^ "\"")
      in
      Error diag
  else
    Ok (Literal located)

let is_leap_year y =
  (y mod 4 = 0 && y mod 100 <> 0) || (y mod 400 = 0)

let days_in_month y m =
  match m with
  | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
  | 4 | 6 | 9 | 11 -> 30
  | 2 -> if is_leap_year y then 29 else 28
  | _ -> 0

let is_digit c = c >= '0' && c <= '9'

let parse_two_digits s pos =
  if pos + 1 < String.length s && is_digit s.[pos] && is_digit s.[pos + 1] then
    let n =
      (Char.code s.[pos] - Char.code '0') * 10
      + (Char.code s.[pos + 1] - Char.code '0')
    in
    Some (n, pos + 2)
  else
    None

let parse_four_digits s pos =
  if pos + 3 < String.length s
     && is_digit s.[pos] && is_digit s.[pos + 1]
     && is_digit s.[pos + 2] && is_digit s.[pos + 3]
  then
    let n =
      (Char.code s.[pos] - Char.code '0') * 1000
      + (Char.code s.[pos + 1] - Char.code '0') * 100
      + (Char.code s.[pos + 2] - Char.code '0') * 10
      + (Char.code s.[pos + 3] - Char.code '0')
    in
    Some (n, pos + 4)
  else
    None

let match_char s pos expected =
  pos < String.length s && s.[pos] = expected

let valid_date s =
  let len = String.length s in
  match len with
  | 10 (* YYYY-MM-DD *) ->
    (match parse_four_digits s 0 with
     | Some (year, 4) when match_char s 4 '-' ->
       (match parse_two_digits s 5 with
        | Some (month, 7) when match_char s 7 '-' ->
          (match parse_two_digits s 8 with
           | Some (day, 10) ->
             month >= 1 && month <= 12
             && day >= 1 && day <= days_in_month year month
           | _ -> false)
        | _ -> false)
     | _ -> false)
  | 20 (* YYYY-MM-DDTHH:MM:SSZ *) ->
    (match parse_four_digits s 0 with
     | Some (year, 4) when match_char s 4 '-' ->
       (match parse_two_digits s 5 with
        | Some (month, 7) when match_char s 7 '-' ->
          (match parse_two_digits s 8 with
           | Some (day, 10) when match_char s 10 'T' ->
             month >= 1 && month <= 12
             && day >= 1 && day <= days_in_month year month
             && (match parse_two_digits s 11 with
                | Some (hour, 13) when match_char s 13 ':' ->
                  (match parse_two_digits s 14 with
                   | Some (minute, 16) when match_char s 16 ':' ->
                     (match parse_two_digits s 17 with
                      | Some (second, 19) when match_char s 19 'Z' ->
                        hour <= 23 && minute <= 59 && second <= 59
                      | _ -> false)
                   | _ -> false)
                | _ -> false)
           | _ -> false)
        | _ -> false)
     | _ -> false)
  | 25 (* YYYY-MM-DDTHH:MM:SS+HH:MM or -HH:MM *) ->
    (match parse_four_digits s 0 with
     | Some (year, 4) when match_char s 4 '-' ->
       (match parse_two_digits s 5 with
        | Some (month, 7) when match_char s 7 '-' ->
          (match parse_two_digits s 8 with
           | Some (day, 10) when match_char s 10 'T' ->
             month >= 1 && month <= 12
             && day >= 1 && day <= days_in_month year month
             && (match parse_two_digits s 11 with
                | Some (hour, 13) when match_char s 13 ':' ->
                  (match parse_two_digits s 14 with
                   | Some (minute, 16) when match_char s 16 ':' ->
                     (match parse_two_digits s 17 with
                      | Some (second, 19)
                        when (match_char s 19 '+' || match_char s 19 '-')
                        ->
                        hour <= 23 && minute <= 59 && second <= 59
                        && (match parse_two_digits s 20 with
                           | Some (off_hour, 22) when match_char s 22 ':' ->
                             (match parse_two_digits s 23 with
                              | Some (off_min, 25) ->
                                off_hour <= 23 && off_min <= 59
                              | _ -> false)
                           | _ -> false)
                      | _ -> false)
                   | _ -> false)
                | _ -> false)
           | _ -> false)
        | _ -> false)
     | _ -> false)
  | _ -> false


(* ── Reading the mapping: which keys tree-md interprets ── *)

(* Meta names that may be written as top-level keys instead of nested under
   `meta:`, so that an editor showing front matter as a property list can edit
   them directly. *)
let promoted_meta_keys =
  ["position"; "institution"; "venue"; "source"; "doi"; "orcid";
   "external"; "slides"; "video"; "bibtex"; "author"; "toc"; "lang"]

let reserved_keys =
  ["id"; "date"; "taxon"; "authors"; "contributors"; "tags"; "meta"]

let known_keys = reserved_keys @ promoted_meta_keys

let tm101 ?mdbase_code span message =
  Diagnostic.make ?mdbase_code TM101 (Span.Source_span span) message

let warn101 ?mdbase_code span message =
  Diagnostic.warn ?mdbase_code TM101 (Span.Source_span span) message

let levenshtein a b =
  let la = String.length a and lb = String.length b in
  if la = 0 then lb
  else if lb = 0 then la
  else begin
    let previous = Array.init (lb + 1) (fun j -> j) in
    let current = Array.make (lb + 1) 0 in
    for i = 1 to la do
      current.(0) <- i;
      for j = 1 to lb do
        let substitution = if a.[i - 1] = b.[j - 1] then 0 else 1 in
        current.(j) <-
          min (min (previous.(j) + 1) (current.(j - 1) + 1))
            (previous.(j - 1) + substitution)
      done;
      Array.blit current 0 previous 0 (lb + 1)
    done;
    previous.(lb)
  end

(* An unknown key is carried, not rejected — an Obsidian vault is full of keys
   that are no business of this compiler. But a key that is one or two edits
   from one tree-md does know is far more likely a typo than a property, and
   silently dropping `taxo:` would lose a `\taxon{}` with nothing to show for
   it. So that case, and only that case, is said out loud. *)
(* [extra] carries the collection's configured address key, so that a forest
   setting `id_field: uid` is not told `uid` looks like a mistake for `id`. *)
let did_you_mean ~extra name =
  let known = extra @ known_keys in
  let lowered = String.lowercase_ascii name in
  if String.length name <= 2 then None
  else if String.length name >= 2 && String.sub name 0 2 = "x-" then None
  else if List.mem lowered known then None
  else
    List.find_opt
      (fun candidate ->
        let budget =
          if min (String.length lowered) (String.length candidate) <= 5 then 1 else 2
        in
        levenshtein lowered candidate <= budget)
      known

(* A scalar read as text. The bytes as written are used rather than the value
   YAML resolved them to, so `taxon: 1.50` keeps `1.50`. An explicit null reads
   as absent: a note that writes `taxon:` and nothing else has no taxon. *)
let scalar_text (node : Yaml_json.t) =
  match node.Yaml_json.value with
  | Yaml_json.Null -> None
  | _ -> Yaml_json.as_text node

let string_field ~name (node : Yaml_json.t) =
  match scalar_text node with
  | Some text -> Ok (Some { value = text; span = node.Yaml_json.span })
  | None -> (
    match node.Yaml_json.value with
    | Yaml_json.Null -> Ok None
    | other ->
      Error
        (tm101 ~mdbase_code:"schema_type" node.Yaml_json.span
           (name ^ " must be a string, not " ^ Yaml_json.describe other)))

(* A list of strings, written either as a YAML list or — as Obsidian often
   writes a single tag — as one bare scalar. *)
let string_list ~name (node : Yaml_json.t) =
  match node.Yaml_json.value with
  | Yaml_json.Null -> Ok []
  | Yaml_json.List items ->
    let rec loop acc = function
      | [] -> Ok (List.rev acc)
      | (item : Yaml_json.t) :: rest -> (
        match scalar_text item with
        | Some text -> loop ({ value = text; span = item.Yaml_json.span } :: acc) rest
        | None ->
          Error
            (tm101 ~mdbase_code:"schema_type" item.Yaml_json.span
               (name ^ " entries must be strings, not "
                ^ Yaml_json.describe item.Yaml_json.value)))
    in
    loop [] items
  | Yaml_json.Assoc _ ->
    Error
      (tm101 ~mdbase_code:"schema_type" node.Yaml_json.span
         (name ^ " must be a string or a list of strings, not a mapping"))
  | _ -> (
    match scalar_text node with
    | Some text -> Ok [ { value = text; span = node.Yaml_json.span } ]
    | None -> Ok [])

(* [id_field] is `settings.id_field` from mdbase.yaml, which names the key a
   collection addresses its records by. It defaults to `id`. *)
let of_yaml ?(id_field = "id") (frontmatter : Yaml_json.t option) =
  match frontmatter with
  | None -> (empty, [])
  | Some node ->
    let diags = ref [] in
    let add diagnostic = diags := diagnostic :: !diags in
    let metadata = ref empty in
    let meta_entries = ref [] in

    (* One meta name may be set once, whether it was written at the top level
       or under `meta:`. *)
    let add_meta (key : string located) (value : string located) =
      if List.exists (fun ((k : string located), _) -> k.value = key.value) !meta_entries
      then
        add (tm101 key.span ("duplicate meta key: \"" ^ key.value ^ "\""))
      else meta_entries := (key, value) :: !meta_entries
    in

    let attributions ~name node assign =
      match string_list ~name node with
      | Error diagnostic -> add diagnostic
      | Ok values ->
        let parsed =
          List.filter_map
            (fun located ->
              match parse_attribution located with
              | Ok attribution -> Some attribution
              | Error diagnostic -> add diagnostic; None)
            values
        in
        assign parsed
    in

    List.iter
      (fun (field : Yaml_json.field) ->
        let name = field.Yaml_json.name in
        let value = field.Yaml_json.value in
        match name with
        | _ when String.equal name id_field -> (
          match string_field ~name value with
          | Error diagnostic -> add diagnostic
          | Ok None -> ()
          | Ok (Some located) ->
            if valid_id located.value then
              metadata := { !metadata with id = Some located }
            else
              add
                (tm101 ~mdbase_code:"schema_pattern" located.span
                   ("invalid id: \"" ^ located.value ^ "\"")))
        | "date" -> (
          match string_field ~name value with
          | Error diagnostic -> add diagnostic
          | Ok None -> ()
          | Ok (Some located) ->
            if valid_date located.value then
              metadata := { !metadata with date = Some located }
            else
              add
                (tm101 ~mdbase_code:"format_invalid" located.span
                   ("invalid date: \"" ^ located.value ^ "\"")))
        | "taxon" -> (
          match string_field ~name value with
          | Error diagnostic -> add diagnostic
          | Ok None -> ()
          | Ok (Some located) -> metadata := { !metadata with taxon = Some located })
        | "authors" ->
          attributions ~name value (fun parsed ->
            metadata := { !metadata with authors = !metadata.authors @ parsed })
        | "contributors" ->
          attributions ~name value (fun parsed ->
            metadata :=
              { !metadata with contributors = !metadata.contributors @ parsed })
        | "tags" -> (
          match string_list ~name value with
          | Error diagnostic -> add diagnostic
          | Ok values -> metadata := { !metadata with tags = !metadata.tags @ values })
        | "meta" -> (
          match value.Yaml_json.value with
          | Yaml_json.Null -> ()
          | Yaml_json.Assoc entries ->
            List.iter
              (fun (entry : Yaml_json.field) ->
                match string_field ~name:("meta." ^ entry.Yaml_json.name)
                        entry.Yaml_json.value with
                | Error diagnostic -> add diagnostic
                | Ok None -> ()
                | Ok (Some located) ->
                  add_meta
                    { value = entry.Yaml_json.name; span = entry.Yaml_json.name_span }
                    located)
              entries
          | other ->
            add
              (tm101 ~mdbase_code:"schema_type" value.Yaml_json.span
                 ("meta must be a mapping, not " ^ Yaml_json.describe other)))
        | _ when List.mem name promoted_meta_keys -> (
          match string_field ~name value with
          | Error diagnostic -> add diagnostic
          | Ok None -> ()
          | Ok (Some located) ->
            add_meta { value = name; span = field.Yaml_json.name_span } located)
        | _ -> (
          (* Everything else is carried, not rejected. *)
          match did_you_mean ~extra:[ id_field ] name with
          | None -> ()
          | Some suggestion ->
            add
              (warn101 ~mdbase_code:"schema_additional_properties"
                 field.Yaml_json.name_span
                 ("unknown front matter key \"" ^ name ^ "\"; did you mean \""
                  ^ suggestion ^ "\"?"))))
      (Yaml_json.fields node);

    ({ !metadata with meta = List.rev !meta_entries }, List.rev !diags)

let lower_inline_values ~parse (raw : raw) =
  let all_diags = ref [] in
  let warnings = ref [] in

  (* Lower each tag value through the inline parser *)
  let lower_tag (tag : string located) =
    match parse tag with
    | Ok (inlines, warns) ->
      warnings := !warnings @ warns;
      Ok { value = inlines; span = tag.span }
    | Error diags ->
      all_diags := diags @ !all_diags;
      Error ()
  in

  (* Lower each meta value through the inline parser *)
  let lower_meta_entry ((key, value) : string located * string located) =
    match parse value with
    | Ok (inlines, warns) ->
      warnings := !warnings @ warns;
      Ok (key, { value = inlines; span = value.span })
    | Error diags ->
      all_diags := diags @ !all_diags;
      Error ()
  in

  let tags_result = List.map lower_tag raw.tags in
  let meta_result = List.map lower_meta_entry raw.meta in

  let ok_tags = List.filter_map (function Ok v -> Some v | Error _ -> None) tags_result in
  let ok_meta = List.filter_map (function Ok v -> Some v | Error _ -> None) meta_result in

  if !all_diags <> [] then
    Error !all_diags
  else
    Ok ({
      date = raw.date;
      taxon = raw.taxon;
      authors = raw.authors;
      contributors = raw.contributors;
      tags = ok_tags;
      meta = ok_meta;
    }, !warnings)
