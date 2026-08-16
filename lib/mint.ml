type minted = { path : string; id : string }

let read_file path =
  match In_channel.with_open_bin path In_channel.input_all with
  | contents -> Ok contents
  | exception Sys_error message ->
    Error [ Diagnostic.make TM404 (Span.Path path) ("cannot read source: " ^ message) ]

(* An address is minted only for a tree that states none; one that is written
   down is left exactly as it is. *)
let states_id contents path =
  match Source.of_string ~path contents with
  | Error _ -> Ok false (* let the compiler report the encoding fault *)
  | Ok source -> (
    match Frontmatter.parse source with
    | Error _ -> Ok false (* likewise: not this pass's diagnostic to make *)
    | Ok fm -> Ok (fm.Frontmatter.metadata.Metadata.id <> None))

(* Sequential picks the lowest free number so that a forest reads in the order
   it grew; random spreads them out, which is what several contributors want. *)
let next_free (policy : Config.id_policy) taken used =
  let is_free n =
    let id = Tree_id.encode policy n in
    not (List.mem id taken) && not (List.mem id used)
  in
  match policy.Config.scheme with
  | Config.Sequential ->
    let rec search n = if is_free n then n else search (n + 1) in
    search 1
  | Config.Random ->
    let span = int_of_float (36. ** float_of_int policy.Config.width) in
    let rec search attempts =
      if attempts > 10_000 then
        (* Effectively full; fall back to the first free number rather than
           spinning, so a build still completes. *)
        let rec linear n = if is_free n then n else linear (n + 1) in
        linear 1
      else
        let n = Random.int (max 1 span) in
        if is_free n then n else search (attempts + 1)
    in
    search 0

let plan config ~taken discovery =
  let policy = config.Config.id in
  let rec loop acc used = function
    | [] -> Ok (List.rev acc)
    | (record : Discovery.source_file) :: rest -> (
      match read_file record.Discovery.path with
      | Error diagnostics -> Error diagnostics
      | Ok contents -> (
        match states_id contents record.Discovery.path with
        | Error diagnostics -> Error diagnostics
        | Ok true -> loop acc used rest
        | Ok false ->
          let id = Tree_id.encode policy (next_free policy taken used) in
          loop ({ path = record.Discovery.path; id } :: acc) (id :: used) rest))
  in
  loop [] [] discovery.Discovery.sources

(* Front matter may not exist yet, in which case the address brings it into
   being. Everything already in the file keeps its bytes. *)
let with_id contents id =
  let line = "id: " ^ id ^ "\n" in
  let opens_frontmatter =
    String.length contents >= 4
    && String.sub contents 0 3 = "---"
    && (contents.[3] = '\n' || (contents.[3] = '\r' && String.length contents > 4))
  in
  if opens_frontmatter then
    let after = if contents.[3] = '\r' then 5 else 4 in
    String.sub contents 0 after ^ line
    ^ String.sub contents after (String.length contents - after)
  else "---\n" ^ line ^ "---\n\n" ^ contents

let write_file path contents =
  (* Same file, replaced in one step, so an interrupted write cannot leave a
     note half-rewritten. *)
  let temporary = path ^ ".tree-md-id" in
  match
    Out_channel.with_open_bin temporary (fun channel ->
      Out_channel.output_string channel contents;
      Out_channel.flush channel);
    Unix.rename temporary path
  with
  | () -> Ok ()
  | exception Sys_error message ->
    Error [ Diagnostic.make TM404 (Span.Path path) ("cannot write source: " ^ message) ]
  | exception Unix.Unix_error (error, _, _) ->
    Error
      [ Diagnostic.make TM404 (Span.Path path)
          ("cannot write source: " ^ Unix.error_message error) ]

let apply minted =
  let rec loop = function
    | [] -> Ok ()
    | { path; id } :: rest -> (
      match read_file path with
      | Error diagnostics -> Error diagnostics
      | Ok contents -> (
        match write_file path (with_id contents id) with
        | Error diagnostics -> Error diagnostics
        | Ok () -> loop rest))
  in
  loop minted
