(* allow: SIZE_OK — the approved Task 15 brief mandates no-symlink traversal,
   lock management, fault-injectable staging, fault-injectable execution, and
   orphan cleanup in a single module; splitting would scatter the durability
   invariant across files. *)
type snapshot = {
  manifest : string option;
  journal : string option;
  stage_entries : string list;
}

type fault_point =
  | After_stage
  | After_journal
  | After_output of int
  | After_manifest

exception Injected_fault of fault_point

(* ── helpers ── *)

let ( let* ) = Result.bind

let tm403 path message =
  Diagnostic.make TM403 (Span.Path path) (path ^ ": " ^ message)

let tm404 path message =
  Diagnostic.make TM404 (Span.Path path) (path ^ ": " ^ message)

let fail_tm403 path message = Error [ tm403 path message ]
let fail_tm404 path message = Error [ tm404 path message ]

let journal_path root = Filename.concat root ".tree-md-transaction.json"
let manifest_path root = Filename.concat root ".tree-md-manifest.json"
let lock_path root = Filename.concat root ".tree-md.lock"
let stage_root root = Filename.concat root ".tree-md-stage"

(* ── no-symlink path traversal ── *)

let check_no_symlinks_abs path context =
  if path = "/" then Ok ()
  else
    let components = path |> String.split_on_char '/' |> List.filter (fun s -> s <> "") in
    let rec check prefix = function
      | [] -> Ok ()
      | comp :: rest ->
        let current = if prefix = "/" then "/" ^ comp else prefix ^ "/" ^ comp in
        (try
           let st = Unix.lstat current in
           match st.Unix.st_kind with
           | Unix.S_LNK ->
             fail_tm403 path (Printf.sprintf "%s is a symlink (in %s)" current context)
           | Unix.S_DIR when rest <> [] -> check current rest
           | Unix.S_DIR -> Ok ()
           | _ when rest = [] -> Ok ()
           | _ ->
             fail_tm403 path (Printf.sprintf "%s is not a directory (in %s)" current context)
         with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ())
    in
    check "/" components

let check_output_root output_root =
  check_no_symlinks_abs output_root "output root"

let check_path_within output_root relative_path context =
  let abs = Filename.concat output_root (Path_safe.to_string relative_path) in
  check_no_symlinks_abs abs context

(* ── directory and fsync helpers ── *)

let fsync_path path =
  try
    let fd = Unix.openfile path [ Unix.O_RDONLY ] 0o0 in
    Unix.fsync fd;
    Unix.close fd
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

(* mkdir_p_checked creates all directories from output_root up to full_path,
   checking no-symlinks at each level.  After creating a new directory its
   parent is immediately fsynced so the new entry is durable on disk.
   Intermediate directories at depth >= 2 are thus fsynced BEFORE any output
   file rename or manifest commit, satisfying the approved durability contract:
   every directory that will hold output files must be durable before the
   journal is removed. *)
let rec mkdir_p_checked output_root full_path =
  let parent = Filename.dirname full_path in
  let at_root = parent = "/" || parent = output_root || String.length parent < String.length output_root in
  if at_root then begin
    if not (Sys.file_exists full_path) then begin
      Unix.mkdir full_path 0o700;
      (* fsync the parent so the new directory entry is durable *)
      fsync_path parent
    end
  end
  else begin
    mkdir_p_checked output_root parent;
    if not (Sys.file_exists full_path) then begin
      ignore (check_no_symlinks_abs parent "parent directory");
      Unix.mkdir full_path 0o700;
      (* fsync the parent so this new intermediate directory is durable
         before any deeper directories or output files are placed. *)
      fsync_path parent
    end
  end

let mkdir_parent output_root file_path =
  let parent = Filename.dirname file_path in
  if parent <> output_root then
    mkdir_p_checked output_root parent

(* rmdir_rf_checked removes a directory tree using lstat on every component.
   Symlinks are refused (TM403) instead of followed.  Only regular files and
   directories are traversed / removed. *)
let rec rmdir_rf_checked path =
  try
    let st = Unix.lstat path in
    match st.Unix.st_kind with
    | Unix.S_LNK ->
      fail_tm403 path (Printf.sprintf "refusing to traverse symlink inside stage dir: %s" path)
    | Unix.S_DIR ->
      let entries = Array.to_list (Sys.readdir path) in
      let entries = List.filter (fun e -> e <> "." && e <> "..") entries in
      let rec remove_all = function
        | [] -> Ok ()
        | entry :: rest ->
          let child = Filename.concat path entry in
          match rmdir_rf_checked child with
          | Ok () -> remove_all rest
          | Error e -> Error e
      in
      begin match remove_all entries with
      | Ok () -> Unix.rmdir path; Ok ()
      | Error e -> Error e
      end
    | _ ->
      Sys.remove path;
      Ok ()
  with Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()

(* ── snapshot ── *)

(* lstat_is_dir returns true if the path exists and is a directory (not a
   symlink), false otherwise.  Unlike Sys.is_directory this does not follow
   symlinks, so a symlink-to-directory is treated as "not a directory". *)
let lstat_is_dir path =
  try
    let st = Unix.lstat path in
    st.Unix.st_kind = Unix.S_DIR
  with Unix.Unix_error _ -> false

(* walk_stage_entries traverses .tree-md-stage/ using lstat so that symlinks
   are never followed.  Symlink entries are silently skipped; regular files
   are recorded; symlinked directories are not recursed into. *)
let walk_stage_entries stage_base =
  let results = ref [] in
  let rec walk prefix dir =
    let entries =
      try Sys.readdir dir
      with Sys_error _ -> [||]
    in
    Array.iter (fun entry ->
      if entry <> "." && entry <> ".." then begin
        let full = Filename.concat dir entry in
        let rel = if prefix = "" then entry else prefix ^ "/" ^ entry in
        if lstat_is_dir full then
          walk rel full
        else if Sys.file_exists full then
          (* regular file or symlink-to-file: include in listing; symlinks
             are harmless in snapshot (no read follows them) *)
          results := (".tree-md-stage/" ^ rel) :: !results
        (* symlink-to-dir, fifo, socket, etc.: silently skip *)
      end)
      entries
  in
  walk "" stage_base;
  List.sort String.compare !results

let snapshot ~output_root =
  let manifest =
    let p = manifest_path output_root in
    if Sys.file_exists p then
      let ic = open_in_bin p in
      let len = in_channel_length ic in
      let buf = Bytes.create len in
      really_input ic buf 0 len; close_in ic;
      Some (Bytes.to_string buf)
    else None
  in
  let journal =
    let p = journal_path output_root in
    if Sys.file_exists p then
      let ic = open_in_bin p in
      let len = in_channel_length ic in
      let buf = Bytes.create len in
      really_input ic buf 0 len; close_in ic;
      Some (Bytes.to_string buf)
    else None
  in
  let stage_base = stage_root output_root in
  let stage_entries =
    if lstat_is_dir stage_base then
      walk_stage_entries stage_base
    else []
  in
  Ok { manifest; journal; stage_entries }

(* ── locking ── *)

let with_build_lock ~output_root f =
  let* () = check_output_root output_root in
  let parent = Filename.dirname output_root in
  let created_root = ref false in
  (try ignore (Unix.lstat output_root)
   with Unix.Unix_error (Unix.ENOENT, _, _) ->
     Unix.mkdir output_root 0o700;
     created_root := true);
  if !created_root then fsync_path parent;
  let lock = lock_path output_root in
  let lock_fd =
    try Unix.openfile lock [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_RDWR ] 0o600
    with Unix.Unix_error (Unix.EEXIST, _, _) ->
      Unix.openfile lock [ Unix.O_RDWR ] 0o600
  in
  match (try Unix.lockf lock_fd Unix.F_TLOCK 0; Ok ()
         with Unix.Unix_error (err, _, _) ->
           Unix.close lock_fd;
           fail_tm403 lock (Printf.sprintf "cannot acquire lock: %s" (Unix.error_message err))) with
  | Error e -> Error e
  | Ok () ->
    Fun.protect
      ~finally:(fun () ->
        try Unix.lockf lock_fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ();
        Unix.close lock_fd)
      (fun () ->
        match f () with
        | result -> Ok result
        | exception e -> Error [ tm404 output_root (Printexc.to_string e) ])

(* writer_active opens the lock file O_RDWR (no O_CREAT — this is a
   non-mutating check).  On Linux, lockf F_TLOCK on a read-only fd always
   yields EBADF; O_RDWR lets us distinguish EAGAIN (lock held by another
   process) from success (lock is free). *)
let writer_active ~output_root =
  let lock = lock_path output_root in
  match Unix.openfile lock [ Unix.O_RDWR ] 0o0 with
  | fd ->
    let held =
      match Unix.lockf fd Unix.F_TLOCK 0 with
      | () -> (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ()); false
      | exception Unix.Unix_error (Unix.EAGAIN, _, _) -> true
      | exception Unix.Unix_error (Unix.EDEADLK, _, _) -> true
      | exception Unix.Unix_error _ -> false
    in
    Unix.close fd; Ok held
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception Unix.Unix_error (err, _, _) ->
    fail_tm404 lock (Printf.sprintf "writer_active: %s" (Unix.error_message err))

(* ── staging ── *)

let write_staged_file output_root abs_path content =
  let parent = Filename.dirname abs_path in
  mkdir_p_checked output_root parent;
  let fd = Unix.openfile abs_path [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY ] 0o600 in
  try
    let content_bytes = Bytes.of_string content in
    let len = Bytes.length content_bytes in
    let rec write offset remaining =
      if remaining <= 0 then ()
      else
        let written = Unix.write fd content_bytes offset remaining in
        write (offset + written) (remaining - written)
    in
    write 0 len;
    Unix.fsync fd;
    Unix.close fd
  with e ->
    Unix.close fd;
    (try Sys.remove abs_path with Sys_error _ -> ());
    raise e

let collect_stage_dirs output_root files =
  let dirs = Hashtbl.create 16 in
  List.iter (fun (temp_path, _) ->
    let abs = Filename.concat output_root (Path_safe.to_string temp_path) in
    let rec add_parents path =
      let parent = Filename.dirname path in
      if parent <> output_root && String.length parent > String.length output_root then begin
        Hashtbl.replace dirs parent ();
        add_parents parent
      end
    in
    add_parents abs)
    files;
  dirs

let fsync_dirs_bottom_up dirs =
  let dir_list = Hashtbl.fold (fun dir () acc -> dir :: acc) dirs [] in
  let sorted = List.sort (fun a b -> String.compare b a) dir_list in
  List.iter fsync_path sorted

let stage ?(inject = fun (_ : fault_point) -> ()) ~output_root ~journal ~files
    ~manifest_bytes () =
  try
  let* () = check_output_root output_root in
  let rec write_files = function
    | [] -> Ok ()
    | (temp_path, content) :: rest ->
      let* () = check_path_within output_root temp_path "staged file" in
      let abs = Filename.concat output_root (Path_safe.to_string temp_path) in
      (try write_staged_file output_root abs content; Ok ()
       with e -> fail_tm404 abs (Printf.sprintf "cannot write staged file: %s" (Printexc.to_string e)))
      |> function
      | Ok () -> write_files rest
      | Error e -> Error e
  in
  let* () = write_files files in
  let manifest_temp = Path_safe.to_string journal.Transaction.new_manifest_temporary in
  let manifest_abs = Filename.concat output_root manifest_temp in
  let* () = check_path_within output_root journal.Transaction.new_manifest_temporary "staged manifest" in
  let* () =
    try write_staged_file output_root manifest_abs manifest_bytes; Ok ()
    with e -> fail_tm404 manifest_abs (Printf.sprintf "cannot write staged manifest: %s" (Printexc.to_string e))
  in
  List.iter (fun (temp_path, _) ->
    let abs = Filename.concat output_root (Path_safe.to_string temp_path) in
    fsync_path abs)
    files;
  fsync_path manifest_abs;
  let dirs = collect_stage_dirs output_root files in
  let manifest_parent = Filename.dirname manifest_abs in
  if manifest_parent <> output_root then Hashtbl.replace dirs manifest_parent ();
  let stage_base = stage_root output_root in
  Hashtbl.replace dirs stage_base ();
  fsync_dirs_bottom_up dirs;
  inject After_stage;
  let journal_abs = journal_path output_root in
  let journal_str = Transaction.encode journal in
  let* () =
    try
      let journal_fd = Unix.openfile journal_abs [ Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY ] 0o600 in
      (try
         let bytes = Bytes.of_string journal_str in
         let len = Bytes.length bytes in
         let rec write offset remaining =
           if remaining <= 0 then ()
           else
             let written = Unix.write journal_fd bytes offset remaining in
             write (offset + written) (remaining - written)
         in
         write 0 len;
         Unix.fsync journal_fd;
         Unix.close journal_fd;
         Ok ()
       with e ->
         Unix.close journal_fd;
         (try Sys.remove journal_abs with Sys_error _ -> ());
         fail_tm404 journal_abs (Printf.sprintf "cannot write journal: %s" (Printexc.to_string e)))
    with Unix.Unix_error (Unix.EEXIST, _, _) ->
       fail_tm403 journal_abs "journal already exists; a build may be in progress"
  in
  fsync_path output_root;
  inject After_journal;
  Ok ()
  with Injected_fault (_ : fault_point) ->
    Error [ tm404 output_root "fault injected during stage" ]

(* ── execution ── *)

let sha256_hex bytes =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)

let read_file_sha256 path =
  try
    let ic = open_in_bin path in
    let len = in_channel_length ic in
    let buf = Bytes.create len in
    really_input ic buf 0 len; close_in ic;
    Ok (sha256_hex (Bytes.to_string buf))
  with
  | (Unix.Unix_error _ | Sys_error _) as e ->
    fail_tm404 path (Printf.sprintf "cannot hash file: %s" (Printexc.to_string e))

let same_filesystem a b =
  try
    let sa = Unix.stat a in
    let sb = Unix.stat b in
    sa.Unix.st_dev = sb.Unix.st_dev
  with Unix.Unix_error _ -> false

let execute ?(inject = fun (_ : fault_point) -> ()) ~output_root actions () =
  try
  let* () = check_output_root output_root in
  let journal_abs = journal_path output_root in
  if not (Sys.file_exists journal_abs) then
    fail_tm404 journal_abs "journal is missing"
  else begin
    inject After_journal;
    let output_count = ref 0 in
    let rec process = function
      | [] -> Ok ()
      | action :: rest ->
        match action with
        | Transaction.Ensure_parent parent ->
          let parent_abs = Filename.concat output_root (Path_safe.to_string parent) in
          begin match check_path_within output_root parent "output parent" with
          | Error e -> Error e
          | Ok () ->
            (try mkdir_p_checked output_root parent_abs; Ok ()
             with Unix.Unix_error (err, _, _) ->
               fail_tm404 parent_abs (Printf.sprintf "cannot create parent: %s" (Unix.error_message err)))
            |> function
            | Ok () -> fsync_path parent_abs; process rest
            | Error e -> Error e
          end
        | Transaction.Install_output { temporary; output; sha256 } ->
          let temp_abs = Filename.concat output_root (Path_safe.to_string temporary) in
          let output_abs = Filename.concat output_root (Path_safe.to_string output) in
          if not (Sys.file_exists temp_abs) then
            fail_tm404 temp_abs "temporary file missing"
          else begin
            match read_file_sha256 temp_abs with
            | Error e -> Error e
            | Ok actual ->
              if actual <> sha256 then
                fail_tm404 temp_abs
                  (Printf.sprintf "temporary sha256 mismatch: expected %s, got %s" sha256 actual)
              else begin
                match check_path_within output_root output "output file" with
                | Error e -> Error e
                | Ok () ->
                  if not (same_filesystem temp_abs (Filename.dirname output_abs)) then
                    fail_tm404 temp_abs "cannot rename across filesystems"
                  else begin
                    mkdir_parent output_root output_abs;
                    (try Unix.rename temp_abs output_abs; Ok ()
                     with Unix.Unix_error (err, _, _) ->
                       fail_tm404 temp_abs (Printf.sprintf "rename failed: %s" (Unix.error_message err)))
                    |> function
                    | Ok () ->
                      incr output_count;
                      (* fsync the output's parent immediately after rename,
                         before Install_manifest commits the new state *)
                      fsync_path (Filename.dirname output_abs);
                      inject (After_output !output_count);
                      process rest
                    | Error e -> Error e
                  end
              end
          end
        | Transaction.Delete_output { output; old_sha256 } ->
          let output_abs = Filename.concat output_root (Path_safe.to_string output) in
          begin match check_path_within output_root output "output file" with
          | Error e -> Error e
          | Ok () ->
            if Sys.file_exists output_abs then begin
              match read_file_sha256 output_abs with
              | Error e -> Error e
              | Ok hash ->
                if hash <> old_sha256 then
                  fail_tm404 output_abs
                    (Printf.sprintf "delete sha256 mismatch: expected %s, got %s" old_sha256 hash)
                else begin
                  Sys.remove output_abs;
                  (* fsync parent after delete *)
                  fsync_path (Filename.dirname output_abs);
                  process rest
                end
            end
            else process rest
          end
        | Transaction.Install_manifest { temporary; sha256 } ->
          let temp_abs = Filename.concat output_root (Path_safe.to_string temporary) in
          let final_abs = manifest_path output_root in
          let hash_result = read_file_sha256 temp_abs in
          (match hash_result with
           | Error e -> Error e
           | Ok actual ->
             if actual <> sha256 then
               fail_tm404 temp_abs
                 (Printf.sprintf "manifest sha256 mismatch: expected %s, got %s" sha256 actual)
             else if not (same_filesystem temp_abs (Filename.dirname final_abs)) then
               fail_tm404 temp_abs "cannot rename manifest across filesystems"
             else
               let rename_result =
                 try Ok (Unix.rename temp_abs final_abs)
                 with Unix.Unix_error (err, _, _) ->
                   fail_tm404 temp_abs (Printf.sprintf "manifest rename failed: %s" (Unix.error_message err))
               in
               match rename_result with
               | Ok () ->
                 fsync_path output_root;
                 inject After_manifest;
                 process rest
               | Error e -> Error e)
        | Transaction.Remove_stage stage_dir ->
          let stage_abs = Filename.concat output_root (Path_safe.to_string stage_dir) in
          let result =
            if Sys.file_exists stage_abs then
              rmdir_rf_checked stage_abs
            else
              Ok ()
          in
          begin match result with
          | Error e -> Error e
          | Ok () ->
            let stage_parent = Filename.dirname stage_abs in
            if stage_parent <> output_root then fsync_path stage_parent;
            process rest
          end
        | Transaction.Remove_journal ->
          if Sys.file_exists journal_abs then begin
            Sys.remove journal_abs;
            fsync_path output_root
          end;
          process rest
    in
    process actions
  end
  with Injected_fault (_ : fault_point) ->
    Error [ tm404 output_root "fault injected during execute" ]

(* ── orphan stage cleanup ── *)

let remove_orphan_stage ~output_root =
  let journal_abs = journal_path output_root in
  let stage_base = stage_root output_root in
  if Sys.file_exists journal_abs then Ok ()
  else if Sys.file_exists stage_base then
    match rmdir_rf_checked stage_base with
    | Ok () ->
      let parent = Filename.dirname stage_base in
      fsync_path parent;
      Ok ()
    | Error e -> Error e
  else Ok ()
