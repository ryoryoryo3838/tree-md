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
