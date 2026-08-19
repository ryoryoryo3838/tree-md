type relative = string

let relative path =
  let invalid message = Error message in
  if path = "" then invalid "path is empty"
  else if path.[0] = '/' then invalid "path is absolute"
  else if String.contains path '\\' then invalid "backslashes are not allowed"
  else if String.contains path '\000' then invalid "NUL bytes are not allowed"
  else if String.length path >= 2 && path.[1] = ':' then
    invalid "path is absolute"
  else
    let segments = String.split_on_char '/' path in
    if List.exists (( = ) "") segments then invalid "path contains an empty segment"
    else if List.exists (( = ) ".") segments then invalid "path contains '.'"
    else if List.exists (( = ) "..") segments then invalid "path contains '..'"
    else Ok path

let to_string path = path

(* `**` crosses separators, `*` and `?` do not. The shape mdbase v0.3 §07 uses
   for `match.path_glob`, and the one `[publish].from` selects with. *)
let glob_matches ~pattern candidate =
  let plen = String.length pattern and clen = String.length candidate in
  let rec go p c =
    if p >= plen then c >= clen
    else
      match pattern.[p] with
      | '*' when p + 1 < plen && pattern.[p + 1] = '*' ->
        let next = if p + 2 < plen && pattern.[p + 2] = '/' then p + 3 else p + 2 in
        let rec try_from i =
          if go next i then true else if i >= clen then false else try_from (i + 1)
        in
        (* `a/**/b` also matches `a/b`, so the skipped run may be empty. *)
        go next c || try_from c
      | '*' ->
        let rec try_from i =
          if go (p + 1) i then true
          else if i >= clen || candidate.[i] = '/' then false
          else try_from (i + 1)
        in
        try_from c
      | '?' -> c < clen && candidate.[c] <> '/' && go (p + 1) (c + 1)
      | ch -> c < clen && candidate.[c] = ch && go (p + 1) (c + 1)
  in
  go 0 0


let append first second = first ^ "/" ^ second

let basename path =
  match String.rindex_opt path '/' with
  | None -> path
  | Some index -> String.sub path (index + 1) (String.length path - index - 1)

let normalize_absolute path =
  let absolute =
    if Filename.is_relative path then Filename.concat (Unix.getcwd ()) path
    else path
  in
  let rec collect segments = function
    | [] -> segments
    | "" :: rest | "." :: rest -> collect segments rest
    | ".." :: rest ->
      (match segments with
       | [] -> collect [] rest
       | _ :: remaining -> collect remaining rest)
    | segment :: rest -> collect (segment :: segments) rest
  in
  match List.rev (collect [] (String.split_on_char '/' absolute)) with
  | [] -> "/"
  | segments -> "/" ^ String.concat "/" segments

let resolve ~base path = normalize_absolute (Filename.concat base path)

let is_within ~root path =
  let root = normalize_absolute root in
  let path = normalize_absolute path in
  root = "/"
  || path = root
  || (String.length path > String.length root
      && String.sub path 0 (String.length root) = root
      && path.[String.length root] = '/')
