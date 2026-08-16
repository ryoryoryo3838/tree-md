(* allow: SIZE_OK — the approved Task 16 brief mandates read-only check
   (config, writer probe, dual snapshots, no-symlink output hashing, and the
   TM301-TM306 state table) and transactional build (recovery-first vs
   fail-fast ordering, pre/post-lock input recheck, managed-hash
   verification, atomic restore of missing unchanged outputs, staged
   transaction execution, and summary derivation) in a single module; the
   observe/mkdir helpers duplicate reviewed Workspace_fs internals that the
   module interface deliberately does not export.

   Read-only check and transactional build workflows. check never creates,
   locks, or writes: it loads configuration, tests writer activity, and
   compares expected state against the manifest and the disk through
   no-symlink reads, reporting TM301-TM306 differences. build owns only the
   manifest and the reserved compiler state, performs every write under the
   exclusive writer lock, and leaves an interrupted transaction recoverable
   through the journal. *)

let ( let* ) = Result.bind

type summary = {
  created : int;
  replaced : int;
  deleted : int;
  unchanged : int;
}

type result = {
  summary : summary;
  (* Addresses this build gave to trees that stated none. Reported rather than
     done quietly: an address is a published URL, so a build that invents one
     has to say so. *)
  minted : Mint.minted list;
  diagnostics : Diagnostic.t list;
}

let zero_summary = { created = 0; replaced = 0; deleted = 0; unchanged = 0 }

let tm path code message = Diagnostic.make code (Span.Path path) message

let manifest_path root = Filename.concat root ".tree-md-manifest.json"
let journal_path root = Filename.concat root ".tree-md-transaction.json"
let stage_path root = Filename.concat root ".tree-md-stage"

let read_file path =
  try
    let ic = open_in_bin path in
    let len = in_channel_length ic in
    let buf = Bytes.create len in
    really_input ic buf 0 len;
    close_in ic;
    Ok (Bytes.to_string buf)
  with
  | Sys_error message ->
    Error [ tm path TM404 ("cannot read file: " ^ message) ]
  | Unix.Unix_error (error, _, _) ->
    Error [ tm path TM404 ("cannot read file: " ^ Unix.error_message error) ]

let sha256 bytes =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string bytes)

(* All relative paths constructed here are internal constants (transaction
   directory names, restore temporary names derived from already-validated
   outputs), so a rejection is a programmer error. *)
let relative value =
  match Path_safe.relative value with
  | Ok path -> path
  | Error message -> invalid_arg (value ^ ": " ^ message)

let fsync_path path =
  try
    let fd = Unix.openfile path [ Unix.O_RDONLY ] 0o0 in
    Unix.fsync fd;
    Unix.close fd
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

module String_map = Map.Make (String)

(* ── no-symlink observation of managed outputs ── *)

type disk_state = Missing | Regular of string | Other

(* Walks every component of a relative path under the output root using
   lstat, so a symlink anywhere along the path is detected without being
   followed. Returns Ok false as soon as a symlink or a non-directory in an
   intermediate position obstructs the path; missing ancestors are fine.
   The final component is not followed: the caller opens it with O_NOFOLLOW
   so a swap after this check is still safe. *)
let safe_components output_root rel =
  let parts = String.split_on_char '/' (Path_safe.to_string rel) in
  let rec walk acc = function
    | [] -> Ok true
    | component :: rest ->
      let rel_path = if acc = "" then component else acc ^ "/" ^ component in
      let abs = Filename.concat output_root rel_path in
      (match Unix.lstat abs with
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok true
       | { Unix.st_kind = Unix.S_LNK; _ } -> Ok false
       | { Unix.st_kind = Unix.S_DIR; _ } -> walk rel_path rest
       | { Unix.st_kind = _; _ } when rest = [] -> Ok true
       | { Unix.st_kind = _; _ } -> Ok false
       | exception Unix.Unix_error (error, _, _) ->
         Error
           [ tm abs TM404
               ("cannot inspect path: " ^ Unix.error_message error) ])
  in
  walk "" parts

(* observe reports the disk state of a managed output without following any
   symlink: every component is lstat-checked first, then the file is opened
   and the descriptor's (dev, ino) is compared with a fresh lstat of the
   path, so a symlink swapped in after the check is refused instead of
   followed. Only regular files are hashed. *)
let observe output_root rel =
  let abs = Filename.concat output_root (Path_safe.to_string rel) in
  match safe_components output_root rel with
  | Error diagnostics -> Error diagnostics
  | Ok false -> Ok Other
  | Ok true ->
    (match Unix.lstat abs with
     | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Missing
     | { Unix.st_kind = Unix.S_REG; _ } ->
       (try
          let fd = Unix.openfile abs [ Unix.O_RDONLY ] 0o0 in
          let opened = Unix.fstat fd in
          match Unix.lstat abs with
          | { Unix.st_kind = Unix.S_REG; st_dev; st_ino; _ }
            when st_dev = opened.Unix.st_dev && st_ino = opened.Unix.st_ino ->
            let ic = Unix.in_channel_of_descr fd in
            let len = opened.Unix.st_size in
            (try
               let bytes = really_input_string ic len in
               close_in ic;
               Ok (Regular (sha256 bytes))
             with
             | Sys_error message ->
               close_in_noerr ic;
               Error [ tm abs TM404 ("cannot read output: " ^ message) ]
             | Unix.Unix_error (error, _, _) ->
               close_in_noerr ic;
               Error
                 [ tm abs TM404
                     ("cannot read output: " ^ Unix.error_message error) ]
             | End_of_file ->
               close_in_noerr ic;
               Error
                 [ tm abs TM404
                     "cannot read output: file truncated while reading" ])
          | _ ->
            (try Unix.close fd with Unix.Unix_error _ -> ());
            Ok Other
        with
        | Unix.Unix_error (error, _, _) ->
          Error
            [ tm abs TM404
                ("cannot read output: " ^ Unix.error_message error) ])
     | { Unix.st_kind = _; _ } -> Ok Other
     | exception Unix.Unix_error (error, _, _) ->
       Error
         [ tm abs TM404
             ("cannot inspect output: " ^ Unix.error_message error) ])

(* Recovery never accepts content outside the states recorded by the
   journal: a non-regular output path is a TM403 recovery precondition
   failure. *)
let observe_transactional output_root rel =
  match observe output_root rel with
  | Error diagnostics -> Error diagnostics
  | Ok Missing -> Ok Transaction.Missing
  | Ok (Regular hash) -> Ok (Transaction.Hash hash)
  | Ok Other ->
    Error
      [ tm (Filename.concat output_root (Path_safe.to_string rel)) TM403
          "output path is not a regular file; recovery refused" ]

(* Precompute the disk observation of every path a journal can consult and
   return a total lookup; any path missing from the table is treated as
   absent, which roll_forward rejects with a TM403 precondition error. *)
let observers output_root paths =
  let observations = Hashtbl.create 8 in
  let* () =
    List.fold_left
      (fun acc path ->
        match acc with
        | Error _ -> acc
        | Ok () ->
          (match observe_transactional output_root path with
           | Error diagnostics -> Error diagnostics
           | Ok observed ->
             Hashtbl.replace observations (Path_safe.to_string path) observed;
             Ok ()))
      (Ok ()) paths
  in
  Ok (fun path ->
    match Hashtbl.find_opt observations (Path_safe.to_string path) with
    | Some observed -> observed
    | None -> Transaction.Missing)

(* ── read-only check ── *)

let compare_states output_root expecteds old_manifest =
  let expected_by_output =
    List.fold_left
      (fun m (e : Compiler.expected) ->
        String_map.add (Path_safe.to_string e.output_relative) e m)
      String_map.empty expecteds
  in
  let manifest_by_output =
    match old_manifest with
    | None -> String_map.empty
    | Some manifest ->
      List.fold_left
        (fun m (entry : Manifest.entry) ->
          String_map.add (Path_safe.to_string entry.output) entry m)
        String_map.empty manifest.Manifest.files
  in
  let diags = ref [] in
  let add diagnostic = diags := diagnostic :: !diags in
  (* Expected outputs: absent → TM301 missing, unknown file in the way →
     TM304 collision, hash mismatch with the manifest → TM302 modified,
     hash match with an outdated manifest → TM303 stale. *)
  String_map.iter
    (fun output (expected : Compiler.expected) ->
      let abs = Filename.concat output_root output in
      match observe output_root expected.Compiler.output_relative with
      | Error diagnostics -> List.iter add diagnostics
      | Ok Missing -> add (tm abs TM301 "missing generated output")
      | Ok Other ->
        (match String_map.find_opt output manifest_by_output with
         | None ->
           add (tm abs TM304 "unknown file occupies an expected output path")
         | Some _ ->
           add
             (tm abs TM302
                "modified generated output: path is not a regular file"))
      | Ok (Regular hash) ->
        (match String_map.find_opt output manifest_by_output with
         | None ->
           add (tm abs TM304 "unknown file occupies an expected output path")
         | Some (entry : Manifest.entry) ->
           if hash = entry.Manifest.sha256 then
             if hash = expected.Compiler.sha256 then ()
             else
               add
                 (tm abs TM303
                    "stale generated output: no longer matches current sources")
           else
             add
               (tm abs TM302
                  "modified generated output: hash does not match the manifest"))
    )
    expected_by_output;
  (* Managed outputs the current sources no longer produce: TM303 stale
     when the hash still matches, TM302 modified otherwise. A managed entry
     whose file is already absent needs no report; the next build drops the
     record. *)
  String_map.iter
    (fun output (entry : Manifest.entry) ->
      if not (String_map.mem output expected_by_output) then
        let abs = Filename.concat output_root output in
        match observe output_root entry.Manifest.output with
        | Error diagnostics -> List.iter add diagnostics
        | Ok Missing -> ()
        | Ok Other ->
          add
            (tm abs TM302
               "modified generated output: path is not a regular file")
        | Ok (Regular hash) ->
          if hash = entry.Manifest.sha256 then
            add
              (tm abs TM303
                 "stale generated output: no longer produced by current sources")
          else
            add
              (tm abs TM302
                 "modified generated output: hash does not match the manifest")
    )
    manifest_by_output;
  List.rev !diags

let finish_check output_root start_snapshot diagnostics =
  match Workspace_fs.snapshot ~output_root with
  | Error d -> { summary = zero_summary; minted = []; diagnostics = List.sort Diagnostic.compare d }
  | Ok end_snapshot ->
    let state_unchanged =
      start_snapshot.Workspace_fs.manifest = end_snapshot.Workspace_fs.manifest
      && start_snapshot.Workspace_fs.journal = end_snapshot.Workspace_fs.journal
      && start_snapshot.Workspace_fs.stage_entries = end_snapshot.Workspace_fs.stage_entries
    in
    if state_unchanged || diagnostics <> [] then
      { summary = zero_summary; minted = []; diagnostics = List.sort Diagnostic.compare diagnostics }
    else
      (* A concurrent writer changed compiler state while check was reading;
         the observed state is unreliable, so success is replaced with an
         exit-code 2 concurrency failure. *)
      { summary = zero_summary;
        minted = [];
        diagnostics =
          [ tm output_root TM404
              "compiler state changed while check was running; re-run check" ] }

let check ~config_path =
  let report diagnostics =
    { summary = zero_summary;
      minted = [];
      diagnostics = List.sort Diagnostic.compare diagnostics }
  in
  match Config.load ~path:config_path with
  | Error diagnostics -> report diagnostics
  | Ok config ->
    let output_root = snd config.Config.output_root in
    (match Workspace_fs.writer_active ~output_root with
     | Error diagnostics -> report diagnostics
     | Ok true ->
       report
         [ tm (Filename.concat output_root ".tree-md.lock") TM404
             "another process holds the build lock; check requires a \
              quiescent workspace" ]
     | Ok false ->
       (match Workspace_fs.snapshot ~output_root with
        | Error diagnostics -> report diagnostics
        | Ok start_snapshot ->
          let state_diags = ref [] in
          let add diagnostic = state_diags := diagnostic :: !state_diags in
          (match start_snapshot.Workspace_fs.journal with
           | Some _ ->
             add
               (tm (journal_path output_root) TM305
                  "incomplete transaction: a previous build was interrupted; \
                   run build to roll it forward")
           | None -> ());
          (match start_snapshot.Workspace_fs.stage_entries with
           | [] -> ()
           | _ ->
             add
               (tm (stage_path output_root) TM306
                  "orphan compiler staging directory: no journal references it"));
          let base_diags () = List.rev !state_diags in
          (match Discovery.scan config with
           | Error diagnostics -> report (base_diags () @ diagnostics)
           | Ok discovery ->
             (match Compiler.compile_forest config discovery with
              | Error diagnostics -> report (base_diags () @ diagnostics)
              | Ok expecteds ->
                (match start_snapshot.Workspace_fs.manifest with
                 | Some bytes ->
                   (match Manifest.decode ~path:(manifest_path output_root) bytes with
                    | Error diagnostics -> report (base_diags () @ diagnostics)
                    | Ok old_manifest ->
                      finish_check output_root start_snapshot
                        (base_diags ()
                         @ compare_states output_root expecteds
                             (Some old_manifest)))
                 | None ->
                   finish_check output_root start_snapshot
                     (base_diags () @ compare_states output_root expecteds None))))))

(* ── transactional build ── *)

let read_old_manifest output_root =
  let path = manifest_path output_root in
  if not (Sys.file_exists path) then Ok None
  else
    match read_file path with
    | Error diagnostics -> Error diagnostics
    | Ok bytes ->
      (match Manifest.decode ~path bytes with
       | Ok manifest -> Ok (Some manifest)
       | Error diagnostics -> Error diagnostics)

(* Before any staging: every file named by the old manifest must still match
   its recorded hash (TM302 modified otherwise), and an expected output not
   named by the old manifest must not collide with an existing file (TM304). *)
let verify_managed output_root old_manifest expecteds =
  let managed_by_output =
    match old_manifest with
    | None -> String_map.empty
    | Some manifest ->
      List.fold_left
        (fun m (entry : Manifest.entry) ->
          String_map.add (Path_safe.to_string entry.output) () m)
        String_map.empty manifest.Manifest.files
  in
  let verify_entries =
    match old_manifest with
    | None -> Ok ()
    | Some manifest ->
      List.fold_left
        (fun acc (entry : Manifest.entry) ->
          match acc with
          | Error _ -> acc
          | Ok () ->
            let abs =
              Filename.concat output_root (Path_safe.to_string entry.output)
            in
            (match observe output_root entry.Manifest.output with
             | Error diagnostics -> Error diagnostics
             | Ok Missing -> Ok ()
             | Ok Other ->
               Error
                 [ tm abs TM302
                     "modified generated output: path is not a regular file" ]
             | Ok (Regular hash) ->
               if hash = entry.Manifest.sha256 then Ok ()
               else
                 Error
                   [ tm abs TM302
                       "modified generated output: hash does not match the \
                        manifest" ]))
        (Ok ()) manifest.Manifest.files
  in
  let* () = verify_entries in
  List.fold_left
    (fun acc (e : Compiler.expected) ->
      match acc with
      | Error _ -> acc
      | Ok () ->
        let output = Path_safe.to_string e.output_relative in
        if String_map.mem output managed_by_output then Ok ()
        else
          let abs = Filename.concat output_root output in
          match observe output_root e.output_relative with
          | Error diagnostics -> Error diagnostics
          | Ok Missing -> Ok ()
          | Ok (Regular _) | Ok Other ->
            Error [ tm abs TM304 "unknown file occupies an expected output path" ])
    (Ok ()) expecteds

(* mkdir_p_checked creates every directory from the output root down to
   [full_path]'s parent, refusing to create below a symlink, and flushes the
   parent of every newly created directory so the new entry is durable
   before any file is placed inside, mirroring the reviewed Workspace_fs
   staging semantics. *)
let rec mkdir_p_checked output_root full_path =
  let parent = Filename.dirname full_path in
  let at_root =
    parent = "/" || parent = output_root
    || String.length parent < String.length output_root
  in
  if at_root then
    if Sys.file_exists full_path then Ok ()
    else
      (try
         Unix.mkdir full_path 0o700;
         fsync_path parent;
         Ok ()
       with Unix.Unix_error (error, _, _) ->
         Error
           [ tm full_path TM404
               ("cannot create directory: " ^ Unix.error_message error) ])
  else
    let* () = mkdir_p_checked output_root parent in
    match Unix.lstat parent with
    | { Unix.st_kind = Unix.S_LNK; _ } ->
      Error [ tm parent TM403 "refusing to create directories below a symlink" ]
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      if Sys.file_exists full_path then Ok ()
      else
        (try
           Unix.mkdir full_path 0o700;
           fsync_path parent;
           Ok ()
         with Unix.Unix_error (error, _, _) ->
           Error
             [ tm full_path TM404
                 ("cannot create directory: " ^ Unix.error_message error) ])
    | { Unix.st_kind = _; _ } ->
      Error [ tm parent TM404 (parent ^ ": parent is not a directory") ]
    | exception Unix.Unix_error (error, _, _) ->
      Error
        [ tm parent TM404
            ("cannot inspect directory: " ^ Unix.error_message error) ]

(* write_staged_atomic writes [bytes] to [temp_abs] with O_EXCL, flushes it,
   renames it onto [output_abs], and flushes the output's parent, so a crash
   never leaves a partially written output file. *)
let write_staged_atomic temp_abs output_abs bytes =
  try
    let fd =
      Unix.openfile temp_abs [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
    in
    (try
       let content = Bytes.of_string bytes in
       let len = Bytes.length content in
       let rec write offset =
         if offset < len then
           let n = Unix.write fd content offset (len - offset) in
           write (offset + n)
         else ()
       in
       write 0;
       Unix.fsync fd;
       Unix.close fd
     with e ->
       (try Unix.close fd with Unix.Unix_error _ -> ());
       (try Sys.remove temp_abs with Sys_error _ -> ());
       raise e);
    Unix.rename temp_abs output_abs;
    fsync_path (Filename.dirname output_abs);
    Ok ()
  with
  | Unix.Unix_error (error, _, _) ->
    Error [ tm temp_abs TM404 ("cannot restore output: " ^ Unix.error_message error) ]

(* restore_missing_atomic reinstates a managed output whose recorded file is
   absent. The temporary is written inside the reserved staging directory
   under the same transaction id, so the transaction's Remove_stage action
   (or the next build's orphan-stage cleanup) removes any leftover; a crash
   leaves either a missing output or a staged temporary, never partial
   content. The output's parent directory is created (with symlink refusal
   and parent fsync) before the rename, so a manually removed parent subtree
   is rebuilt, mirroring Ensure_parent semantics. *)
let restore_missing_atomic output_root txn_dir (entry : Manifest.entry) bytes =
  let output_abs =
    Filename.concat output_root (Path_safe.to_string entry.Manifest.output)
  in
  let temp_rel =
    Path_safe.append txn_dir
      (relative (Path_safe.to_string entry.Manifest.output ^ ".restore"))
  in
  let temp_abs = Filename.concat output_root (Path_safe.to_string temp_rel) in
  let* () = mkdir_p_checked output_root (Filename.dirname temp_abs) in
  (* the root-level output parent is the output root itself and already
     exists; any deeper parent is created safely before the rename *)
  let* () = mkdir_p_checked output_root (Filename.dirname output_abs) in
  write_staged_atomic temp_abs output_abs bytes

(* A managed output that is absent while its manifest content is unchanged is
   restored atomically before the diff is planned: the journal would record a
   base manifest identical to the new manifest, which roll_forward would
   misread as a completed transaction. The restore keeps the workspace
   consistent without a journal because each file appears atomically and the
   manifest never changes. *)
let restore_unchanged_missing output_root txn_dir old_manifest pure_ops
    bytes_by_output =
  match old_manifest with
  | None -> Ok []
  | Some _ ->
    let restores = ref [] in
    let* () =
      List.fold_left
        (fun acc op ->
          match acc with
          | Error _ -> acc
          | Ok () ->
            (match op with
             | Manifest.Unchanged entry ->
               (match observe output_root entry.Manifest.output with
                | Ok Missing ->
                  restores := entry :: !restores;
                  Ok ()
                | Ok (Regular _) | Ok Other -> Ok ()
                | Error diagnostics -> Error diagnostics)
             | _ -> Ok ()))
        (Ok ()) pure_ops
    in
    let* () =
      List.fold_left
        (fun acc (entry : Manifest.entry) ->
          match acc with
          | Error _ -> acc
          | Ok () ->
            let bytes =
              Hashtbl.find bytes_by_output
                (Path_safe.to_string entry.Manifest.output)
            in
            restore_missing_atomic output_root txn_dir entry bytes)
        (Ok ()) (List.rev !restores)
    in
    Ok (List.rev !restores)

(* The old manifest was just verified, so an unchanged entry is still present
   with its recorded hash (a no-op) once missing ones are restored; a
   replaced entry whose old file is gone becomes a create. *)
let postprocess output_root ops =
  List.fold_left
    (fun acc op ->
      match acc with
      | Error _ -> acc
      | Ok ops ->
        (match op with
         | Manifest.Unchanged entry ->
           (match observe output_root entry.Manifest.output with
            | Ok (Regular hash) when hash = entry.Manifest.sha256 ->
              Ok (Manifest.Unchanged entry :: ops)
            | Ok _ -> Ok (Manifest.Create entry :: ops)
            | Error diagnostics -> Error diagnostics)
         | Manifest.Replace { old_entry; new_entry } ->
           (match observe output_root new_entry.Manifest.output with
            | Ok (Regular hash) when hash = old_entry.Manifest.sha256 ->
              Ok (Manifest.Replace { old_entry; new_entry } :: ops)
            | Ok Missing -> Ok (Manifest.Create new_entry :: ops)
            | Ok (Regular _) | Ok Other ->
              Error
                [ tm
                    (Filename.concat output_root
                       (Path_safe.to_string new_entry.output))
                    TM500
                    "internal: replace output changed between verification \
                     and staging" ]
            | Error diagnostics -> Error diagnostics)
         | (Manifest.Create _ | Manifest.Delete _) as op ->
           Ok (op :: ops)))
    (Ok []) ops
  |> Result.map List.rev

let transaction_id (manifest : Manifest.t) =
  "txn-" ^ String.sub (Manifest.sha256 (Manifest.encode manifest)) 0 6

let expected_bytes expecteds =
  let table = Hashtbl.create (List.length expecteds) in
  List.iter
    (fun (e : Compiler.expected) ->
      Hashtbl.replace table (Path_safe.to_string e.output_relative) e.bytes)
    expecteds;
  table

let journal_paths (transaction : Transaction.t) =
  transaction.Transaction.new_manifest_temporary
  :: List.concat_map
       (fun (op : Transaction.operation) ->
         op.Transaction.output
         :: (match op.Transaction.temporary with
             | Some temporary -> [ temporary ]
             | None -> []))
       transaction.Transaction.operations

let plan_execute output_root transaction =
  let* observed = observers output_root (journal_paths transaction) in
  let* current_manifest =
    let path = manifest_path output_root in
    if Sys.file_exists path then
      match read_file path with
      | Ok bytes -> Ok (Transaction.Hash (Manifest.sha256 bytes))
      | Error diagnostics -> Error diagnostics
    else Ok Transaction.Missing
  in
  Transaction.roll_forward transaction ~current_manifest
    ~output:observed ~temporary:observed

(* Summary counts are derived from the executed transaction only after the
   journal has been removed; outputs restored before staging and outputs kept
   as no-ops make up the remainder of the expected outputs. *)
let count_summary (transaction : Transaction.t) expected_count ~restored =
  let created, replaced, deleted =
    List.fold_left
      (fun (created, replaced, deleted) (op : Transaction.operation) ->
        match op.Transaction.old_sha256, op.Transaction.new_sha256 with
        | None, Some _ -> (created + 1, replaced, deleted)
        | Some _, Some _ -> (created, replaced + 1, deleted)
        | Some _, None -> (created, replaced, deleted + 1)
        | None, None -> (created, replaced, deleted))
      (0, 0, 0) transaction.Transaction.operations
  in
  { created = created + restored;
    replaced;
    deleted;
    unchanged = expected_count - created - replaced - restored }

let normal_build config expecteds =
  let output_root = snd config.Config.output_root in
  let* old_manifest = read_old_manifest output_root in
  let* () = verify_managed output_root old_manifest expecteds in
  let next_manifest = Manifest.of_expected expecteds in
  let txn_id = transaction_id next_manifest in
  let txn_dir = relative (".tree-md-stage/" ^ txn_id) in
  let bytes_by_output = expected_bytes expecteds in
  let pure_ops = Manifest.diff ~old:old_manifest ~next:next_manifest in
  let* restored =
    restore_unchanged_missing output_root txn_dir old_manifest pure_ops
      bytes_by_output
  in
  let* ops = postprocess output_root pure_ops in
  let transaction =
    Transaction.create ~transaction_id:txn_id
      ~old_manifest ~new_manifest:next_manifest ops
  in
  let files =
    List.filter_map
      (fun (op : Transaction.operation) ->
        match op.Transaction.temporary with
        | Some temporary ->
          Some
            (temporary,
             Hashtbl.find bytes_by_output
               (Path_safe.to_string op.Transaction.output))
        | None -> None)
      transaction.Transaction.operations
  in
  let* () =
    Workspace_fs.stage ~output_root ~journal:transaction ~files
      ~manifest_bytes:(Manifest.encode next_manifest) ()
  in
  let* actions = plan_execute output_root transaction in
  let* () = Workspace_fs.execute ~output_root actions () in
  Ok
    (count_summary transaction (List.length expecteds)
       ~restored:(List.length restored))

(* ── recovery under the writer lock ── *)

let recover output_root =
  match Workspace_fs.snapshot ~output_root with
  | Error diagnostics -> Error diagnostics
  | Ok snap ->
    (match snap.Workspace_fs.journal with
     | Some journal_bytes ->
       let* journal =
         match Transaction.decode ~path:(journal_path output_root) journal_bytes with
         | Ok journal -> Ok journal
         | Error diagnostics -> Error diagnostics
       in
       let* current_manifest =
         match snap.Workspace_fs.manifest with
         | None -> Ok Transaction.Missing
         | Some bytes -> Ok (Transaction.Hash (Manifest.sha256 bytes))
       in
       let* observed = observers output_root (journal_paths journal) in
       let* actions =
         Transaction.roll_forward journal ~current_manifest
           ~output:observed ~temporary:observed
       in
       Workspace_fs.execute ~output_root actions ()
     | None ->
       if snap.Workspace_fs.stage_entries = [] then Ok ()
       else Workspace_fs.remove_orphan_stage ~output_root)

(* ── input recheck under the lock ── *)

let compile config =
  match Discovery.scan config with
  | Error diagnostics -> Error diagnostics
  | Ok discovery ->
    (match Compiler.compile_forest config discovery with
     | Error diagnostics -> Error diagnostics
     | Ok expecteds -> Ok (expecteds, discovery))

(* Digest of every file a compile consumes: the compiler configuration, the
   forest configuration, every discovered source, and every handwritten root.
   None on any read failure, which forces a recompile under the lock. *)
let input_digests config discovery =
  let paths =
    List.sort_uniq String.compare
      (config.Config.path :: config.Config.forest.Config.path
       :: List.map (fun (r : Discovery.source_file) -> r.Discovery.path)
            discovery.Discovery.sources
       @ List.map (fun (r : Discovery.handwritten_root) -> r.Discovery.path)
            discovery.Discovery.handwritten_roots)
  in
  let rec loop acc = function
    | [] -> Some (List.rev acc)
    | path :: rest ->
      (match read_file path with
       | Error _ -> None
       | Ok bytes -> loop ((path, sha256 bytes) :: acc) rest)
  in
  loop [] paths

(* A re-scan under the lock also detects source files added or removed since
   the pre-lock discovery, which per-file digests cannot see. *)
let rescan_unchanged config discovery =
  match Discovery.scan config with
  | Error _ -> false
  | Ok fresh ->
    let paths (d : Discovery.t) =
      List.map (fun (r : Discovery.source_file) -> r.Discovery.path)
        d.Discovery.sources
      @ List.map (fun (r : Discovery.handwritten_root) -> r.Discovery.path)
          d.Discovery.handwritten_roots
      |> List.sort String.compare
    in
    paths fresh = paths discovery

let lock_and_build config f =
  match Workspace_fs.with_build_lock ~output_root:(snd config.Config.output_root) f with
  | Ok result -> result
  | Error diagnostics ->
    { summary = zero_summary; minted = []; diagnostics = List.sort Diagnostic.compare diagnostics }

(* Give an address to every tree that states none, and write it into the note.
   Run only once the forest has compiled: a forest that does not compile is
   never rewritten, the same promise the output side already makes.

   The identities come from a real parse of the whole forest rather than a
   guess, because minting a collision would publish two trees at one URL — and
   the address is in the source by the time anything could notice. *)
let mint_addresses config discovery =
  match config.Config.id.Config.mint with
  | Config.Off -> Ok []
  | Config.By_build -> (
    match Compiler.identities config discovery with
    | Error diagnostics -> Error diagnostics
    | Ok taken -> (
      match Mint.plan config ~taken discovery with
      | Error diagnostics -> Error diagnostics
      | Ok [] -> Ok []
      | Ok planned -> (
        match Mint.apply planned with
        | Error diagnostics -> Error diagnostics
        | Ok () -> Ok planned)))

let build ~config_path =
  let report diagnostics =
    { summary = zero_summary; minted = [];
      diagnostics = List.sort Diagnostic.compare diagnostics }
  in
  match Config.load ~path:config_path with
  | Error diagnostics -> report diagnostics
  | Ok config ->
    let output_root = snd config.Config.output_root in
    (match Workspace_fs.snapshot ~output_root with
     | Error diagnostics -> report diagnostics
     | Ok probe ->
       let recovery_needed =
         probe.Workspace_fs.journal <> None || probe.Workspace_fs.stage_entries <> []
       in
       if recovery_needed then
         (* Recovery takes the lock first, completes the recorded transaction,
            then compiles current source under the same lock. *)
         lock_and_build config (fun () ->
           match
             (let* () = recover output_root in
              let* expecteds, _discovery = compile config in
              normal_build config expecteds)
           with
           | Error diagnostics -> report diagnostics
           | Ok summary -> { summary; minted = []; diagnostics = [] })
       else
         (* No journal and no orphan stage: compile and validate before any
            output state is created, so a failing forest never writes. *)
         match compile config with
         | Error diagnostics -> report diagnostics
         | Ok (first_expecteds, first_discovery) ->
         (* Addresses are handed out only to a forest that compiles, and the
            recompile is what turns them into the outputs' names. *)
         match mint_addresses config first_discovery with
         | Error diagnostics -> report diagnostics
         | Ok minted ->
         match
           (if minted = [] then Ok (first_expecteds, first_discovery)
            else compile config)
         with
         | Error diagnostics -> report diagnostics
         | Ok (expecteds, discovery) ->
           let pre_digests = input_digests config discovery in
           lock_and_build config (fun () ->
             match
               (match Workspace_fs.snapshot ~output_root with
                | Error diagnostics -> Error diagnostics
                | Ok snap ->
                  if snap.Workspace_fs.journal <> None
                     || snap.Workspace_fs.stage_entries <> [] then
                    (* a concurrent writer crashed while we compiled without
                       the lock: recover before compiling current source *)
                    (let* () = recover output_root in
                     let* expecteds, _discovery = compile config in
                     normal_build config expecteds)
                  else
                    let inputs_changed =
                      match pre_digests with
                      | None -> true
                      | Some pre ->
                        input_digests config discovery <> Some pre
                        || not (rescan_unchanged config discovery)
                    in
                    if inputs_changed then
                      let* expecteds, _discovery = compile config in
                      normal_build config expecteds
                    else normal_build config expecteds)
             with
             | Error diagnostics -> report diagnostics
             | Ok summary -> { summary; minted; diagnostics = [] }))
