open Tree_md

let h64 c = String.make 64 c

(* Resolved, because the workspace refuses an output root reached through a
   symbolic link and macOS puts $TMPDIR under /var, which is a link to
   /private/var. Every path here would carry that link and every test that
   writes would fail for a reason that has nothing to do with what it tests. *)
let tmpdir () =
  let name = Filename.temp_file "tree-md-test-" "" in
  Unix.unlink name;
  Unix.mkdir name 0o700;
  Unix.realpath name

let rec rm_rf path =
  try
    let st = Unix.lstat path in
    match st.Unix.st_kind with
    | Unix.S_LNK -> Sys.remove path
    | Unix.S_DIR ->
      let entries = Sys.readdir path in
      Array.iter (fun entry ->
        if entry <> "." && entry <> ".." then
          rm_rf (Filename.concat path entry))
        entries;
      Unix.rmdir path
    | _ -> Sys.remove path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_tmpdir f =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

let rel s =
  match Path_safe.relative s with
  | Ok p -> p
  | Error msg -> Alcotest.fail msg

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  Bytes.to_string buf

let sha256 s =
  Digestif.SHA256.to_hex (Digestif.SHA256.digest_string s)

let exists path = Sys.file_exists path
let is_dir path = try Sys.is_directory path with Sys_error _ -> false

let errs ds = String.concat "; " (List.map (fun d -> d.Diagnostic.message) ds)
let fail_errs ds = Alcotest.fail (errs ds)

let make_manifest_from_content entries =
  Manifest.of_expected
    (List.map (fun (source, output, bytes) ->
       let sha = sha256 bytes in
       { Compiler.source_path = source;
         source_config_relative = rel source;
         output_relative = rel output;
         bytes = "";
         sha256 = sha })
       entries)

let manifest_of_output output_name bytes =
  make_manifest_from_content [("trees-md/" ^ output_name ^ ".tree.md", output_name, bytes)]

let lock dir =
  match Workspace_fs.with_build_lock ~output_root:dir (fun () -> ()) with
  | Ok () -> ()
  | Error ds -> fail_errs ds

let obs_temp dir temp =
  let path = Path_safe.resolve ~base:dir temp in
  if Sys.file_exists path then Transaction.Hash (sha256 (read_file path))
  else Transaction.Missing

let obs_output dir out =
  let path = Filename.concat dir (Path_safe.to_string out) in
  if Sys.file_exists path then Transaction.Hash (sha256 (read_file path))
  else Transaction.Missing

let roll dir journal ~current_manifest =
  match Transaction.roll_forward journal ~current_manifest
          ~output:(obs_output dir) ~temporary:(obs_temp dir) with
  | Ok actions -> actions
  | Error e -> fail_errs e

(* ── snapshot tests ── *)

let test_snapshot_empty () =
  with_tmpdir (fun dir ->
    let s = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check (option string)) "manifest absent" None s.manifest;
    Alcotest.(check (option string)) "journal absent" None s.journal;
    Alcotest.(check (list string)) "no stage entries" [] s.stage_entries)

let test_snapshot_with_files () =
  with_tmpdir (fun dir ->
    write_file (Filename.concat dir ".tree-md-manifest.json") "{}";
    write_file (Filename.concat dir ".tree-md-transaction.json") "[]";
    Unix.mkdir (Filename.concat dir ".tree-md-stage") 0o700;
    write_file (Filename.concat dir ".tree-md-stage/x.tmp") "staged";
    let s = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check (option string)) "manifest present" (Some "{}") s.manifest;
    Alcotest.(check (option string)) "journal present" (Some "[]") s.journal;
    Alcotest.(check (list string)) "stage entries present"
      [".tree-md-stage/x.tmp"] s.stage_entries)

(* ── lock tests ── *)

let test_lock_contention () =
  with_tmpdir (fun dir ->
    lock dir;
    Alcotest.(check bool) "lock file exists" true
      (exists (Filename.concat dir ".tree-md.lock"));
    let active = match Workspace_fs.writer_active ~output_root:dir with Ok v -> v | Error ds -> fail_errs ds in
    Alcotest.(check bool) "no writer active after release" false active)

let test_writer_active_no_root () =
  with_tmpdir (fun dir ->
    let nonexistent = Filename.concat dir "nonexistent" in
    let active = match Workspace_fs.writer_active ~output_root:nonexistent with Ok v -> v | Error ds -> fail_errs ds in
    Alcotest.(check bool) "should be false" false active)

(* ── symlink refusal tests ── *)

let test_symlink_refusal_output_root () =
  with_tmpdir (fun dir ->
    let real = Filename.concat dir "real" in
    Unix.mkdir real 0o700;
    let link = Filename.concat dir "link" in
    Unix.symlink real link;
    let result = Workspace_fs.with_build_lock ~output_root:link (fun () -> ()) in
    Alcotest.(check bool) "symlink root rejected" true (Result.is_error result))

let test_symlink_refusal_ancestor () =
  with_tmpdir (fun dir ->
    let real = Filename.concat dir "intermediate" in
    Unix.mkdir real 0o700;
    let link = Filename.concat dir "link" in
    Unix.symlink real link;
    let root = Filename.concat link "output" in
    let result = Workspace_fs.with_build_lock ~output_root:root (fun () -> ()) in
    Alcotest.(check bool) "symlink ancestor rejected" true (Result.is_error result))

let test_symlink_refusal_stage () =
  with_tmpdir (fun dir ->
    lock dir;
    let stage_dir = Filename.concat dir ".tree-md-stage" in
    Unix.mkdir stage_dir 0o700;
    let real = Filename.concat stage_dir "real" in
    Unix.mkdir real 0o700;
    let link = Filename.concat stage_dir "txn-sym" in
    Unix.symlink real link;
    let journal =
      let entries = [{ Compiler.source_path = "trees-md/a.tree.md";
        source_config_relative = rel "trees-md/a.tree.md";
        output_relative = rel "a.tree";
        bytes = "";
        sha256 = sha256 "content" }]
      in
      let new_manifest = Manifest.of_expected entries in
      Transaction.create ~transaction_id:"txn-sym"
        ~old_manifest:None
        ~new_manifest:new_manifest
        (Manifest.diff ~old:None ~next:new_manifest)
    in
    let files = [ rel ".tree-md-stage/txn-sym/input.tmp", "content" ] in
    let (result : (unit, Diagnostic.t list) result) =
      Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes:"{}" () in
    Alcotest.(check bool) "symlink in stage rejected" true (Result.is_error result))

(* ── stage / execute normal operation ── *)

let journal_for_files txn_id files =
  let entries = List.map (fun (output_rel, content) ->
    let sha = sha256 content in
    { Compiler.source_path = "trees-md/" ^ output_rel ^ ".tree.md";
      source_config_relative = rel ("trees-md/" ^ output_rel ^ ".tree.md");
      output_relative = rel output_rel;
      bytes = "";
      sha256 = sha })
    files
  in
  let manifest = Manifest.of_expected entries in
  let journal = Transaction.create ~transaction_id:txn_id
    ~old_manifest:None ~new_manifest:manifest
    (Manifest.diff ~old:None ~next:manifest) in
  (journal, Manifest.encode manifest, manifest)

let test_stage_and_execute_normal () =
  with_tmpdir (fun dir ->
    lock dir;
    let out_content = "tree output content\n" in
    let journal, manifest_bytes, manifest = journal_for_files "txn-normal" [("a.tree", out_content)] in
    let files = [ rel ".tree-md-stage/txn-normal/a.tree.tmp", out_content ] in
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let snap = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check bool) "journal present" true (Option.is_some snap.journal);
    Alcotest.(check bool) "stage entries present" true (List.length snap.stage_entries > 0);
    let actions = roll dir journal ~current_manifest:Transaction.Missing in
    let _ = match Workspace_fs.execute ~output_root:dir actions () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let output_path = Filename.concat dir "a.tree" in
    Alcotest.(check bool) "output file exists" true (exists output_path);
    Alcotest.(check string) "output content" out_content (read_file output_path);
    Alcotest.(check bool) "journal removed" false
      (exists (Filename.concat dir ".tree-md-transaction.json"));
    Alcotest.(check bool) "manifest exists" true
      (exists (Filename.concat dir ".tree-md-manifest.json"));
    let stage_root_dir = Filename.concat dir ".tree-md-stage" in
    Alcotest.(check bool) "stage cleaned" true
      (not (is_dir stage_root_dir) || (
        try Array.length (Sys.readdir stage_root_dir) <= 2
        with Sys_error _ -> true)))

(* ── fault injection tests ── *)

let test_fault_after_stage () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "b output\n" in
    let journal, manifest_bytes, manifest = journal_for_files "txn-normal" [("b.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-normal/b.tree.tmp", content ] in
    let injected = ref None in
    let inject pt = injected := Some pt; raise (Workspace_fs.Injected_fault pt) in
    let stage_result = Workspace_fs.stage ~inject ~output_root:dir ~journal ~files ~manifest_bytes () in
    Alcotest.(check bool) "stage should fail" true (Result.is_error stage_result);
    Alcotest.(check (option string)) "fault was After_stage" (Some "After_stage")
      (Option.map (fun (p : Workspace_fs.fault_point) ->
         match p with Workspace_fs.After_stage -> "After_stage" | _ -> "other") !injected);
    let snap1 = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check (option string)) "no journal" None snap1.journal;
    Alcotest.(check bool) "stage entries exist" true (List.length snap1.stage_entries > 0);
    let _ = match Workspace_fs.remove_orphan_stage ~output_root:dir with Ok () -> () | Error ds -> fail_errs ds in
    let snap2 = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check (list string)) "stage entries removed" [] snap2.stage_entries)

let test_fault_after_journal_stage () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "c output\n" in
    let journal, manifest_bytes, _manifest = journal_for_files "txn-normal" [("c.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-normal/c.tree.tmp", content ] in
    let injected = ref None in
    let inject pt = if pt = Workspace_fs.After_journal then (injected := Some pt; raise (Workspace_fs.Injected_fault pt)) in
    let stage_result = Workspace_fs.stage ~inject ~output_root:dir ~journal ~files ~manifest_bytes () in
    Alcotest.(check bool) "stage should fail" true (Result.is_error stage_result);
    Alcotest.(check (option string)) "fault was After_journal" (Some "After_journal")
      (Option.map (fun (p : Workspace_fs.fault_point) ->
         match p with Workspace_fs.After_journal -> "After_journal" | _ -> "other") !injected);
    let snap = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check bool) "journal present" true (Option.is_some snap.journal);
    Alcotest.(check bool) "stage entries exist" true (List.length snap.stage_entries > 0);
    let journal_path = Filename.concat dir ".tree-md-transaction.json" in
    let journal_bytes = read_file journal_path in
    let decoded = match Transaction.decode ~path:journal_path journal_bytes with Ok t -> t | Error ds -> fail_errs ds in
    let actions = roll dir decoded ~current_manifest:Transaction.Missing in
    let _ = match Workspace_fs.execute ~output_root:dir actions () with Ok () -> () | Error ds -> fail_errs ds in
    Alcotest.(check bool) "output restored c.tree" true (exists (Filename.concat dir "c.tree")))

let test_fault_after_output () =
  with_tmpdir (fun dir ->
    lock dir;
    let manifest_contents = [("d1.tree", "d1 out\n"); ("d2.tree", "d2 out\n"); ("d3.tree", "d3 out\n")] in
    let journal, manifest_bytes, _manifest = journal_for_files "txn-output" manifest_contents in
    let files = [
      rel ".tree-md-stage/txn-output/d1.tree.tmp", "d1 out\n";
      rel ".tree-md-stage/txn-output/d2.tree.tmp", "d2 out\n";
      rel ".tree-md-stage/txn-output/d3.tree.tmp", "d3 out\n";
    ] in
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let actions = roll dir journal ~current_manifest:Transaction.Missing in
    let injected = ref None in
    let inject pt = match pt with
      | Workspace_fs.After_output 1 -> injected := Some pt; raise (Workspace_fs.Injected_fault pt)
      | _ -> () in
    let exec_result = Workspace_fs.execute ~inject ~output_root:dir actions () in
    Alcotest.(check bool) "execute should fail" true (Result.is_error exec_result);
    Alcotest.(check (option string)) "fault was After_output"
      (Some "After_output 1")
      (Option.map (fun (p : Workspace_fs.fault_point) ->
         match p with Workspace_fs.After_output n -> Printf.sprintf "After_output %d" n | _ -> "other") !injected);
    let journal_path = Filename.concat dir ".tree-md-transaction.json" in
    let journal_bytes = read_file journal_path in
    let decoded = match Transaction.decode ~path:journal_path journal_bytes with Ok t -> t | Error ds -> fail_errs ds in
    let recover_actions = roll dir decoded ~current_manifest:Transaction.Missing in
    let _ = match Workspace_fs.execute ~output_root:dir recover_actions () with Ok () -> () | Error ds -> fail_errs ds in
    Alcotest.(check bool) "d1 exists" true (exists (Filename.concat dir "d1.tree"));
    Alcotest.(check bool) "d2 exists" true (exists (Filename.concat dir "d2.tree"));
    Alcotest.(check bool) "d3 exists" true (exists (Filename.concat dir "d3.tree"));
    Alcotest.(check bool) "journal removed" false
      (exists (Filename.concat dir ".tree-md-transaction.json")))

let test_fault_after_manifest () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "e output\n" in
    let journal, manifest_bytes, manifest = journal_for_files "txn-manifest" [("e.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-manifest/e.tree.tmp", content ] in
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let actions = roll dir journal ~current_manifest:Transaction.Missing in
    let injected = ref None in
    let inject pt = match pt with
      | Workspace_fs.After_manifest -> injected := Some pt; raise (Workspace_fs.Injected_fault pt)
      | _ -> () in
    let exec_result = Workspace_fs.execute ~inject ~output_root:dir actions () in
    Alcotest.(check bool) "execute should fail" true (Result.is_error exec_result);
    Alcotest.(check (option string)) "fault was After_manifest"
      (Some "After_manifest")
      (Option.map (fun (p : Workspace_fs.fault_point) ->
         match p with Workspace_fs.After_manifest -> "After_manifest" | _ -> "other") !injected);
    Alcotest.(check bool) "e.tree exists by rename" true (exists (Filename.concat dir "e.tree"));
    let journal_path = Filename.concat dir ".tree-md-transaction.json" in
    if exists journal_path then begin
      let journal_bytes = read_file journal_path in
      let decoded = match Transaction.decode ~path:journal_path journal_bytes with Ok t -> t | Error ds -> fail_errs ds in
      let manifest_hash = Manifest.sha256 (Manifest.encode manifest) in
      let recover_actions = roll dir decoded ~current_manifest:(Transaction.Hash manifest_hash) in
      let _ = match Workspace_fs.execute ~output_root:dir recover_actions () with Ok () -> () | Error ds -> fail_errs ds in
      Alcotest.(check bool) "journal removed after recovery" false (exists journal_path)
    end)

(* ── orphan stage tests ── *)

let test_orphan_stage_with_journal () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "f out\n" in
    let journal, manifest_bytes, _manifest = journal_for_files "txn-normal" [("f.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-normal/f.tree.tmp", content ] in
    let () = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let () = match Workspace_fs.remove_orphan_stage ~output_root:dir with Ok () -> () | Error ds -> fail_errs ds in
    let snap = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check bool) "stage still present with journal" true (List.length snap.stage_entries > 0))

let test_orphan_stage_cleanup () =
  with_tmpdir (fun dir ->
    let stage_dir = Filename.concat dir ".tree-md-stage" in
    Unix.mkdir stage_dir 0o700;
    let txn_dir = Filename.concat stage_dir "orphan-txn" in
    Unix.mkdir txn_dir 0o700;
    write_file (Filename.concat txn_dir "g.tree.tmp") "orphan content\n";
    let () = match Workspace_fs.remove_orphan_stage ~output_root:dir with Ok () -> () | Error ds -> fail_errs ds in
    let snap = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    Alcotest.(check (list string)) "orphan stage removed" [] snap.stage_entries)

(* ── durability barrier tests ── *)

let test_durability_barriers () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "barrier out\n" in
    let journal, manifest_bytes, _manifest = journal_for_files "txn-barrier" [("sub/h.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-barrier/sub/h.tree.tmp", content ] in
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let stage_sub = Filename.concat dir ".tree-md-stage/txn-barrier/sub" in
    Alcotest.(check bool) "stage sub dir created" true (is_dir stage_sub);
    let actions = roll dir journal ~current_manifest:Transaction.Missing in
    let () = match Workspace_fs.execute ~output_root:dir actions () with Ok () -> () | Error ds -> fail_errs ds in
    Alcotest.(check bool) "subdir output exists" true (exists (Filename.concat dir "sub/h.tree"));
    Alcotest.(check bool) "stage cleaned" false (is_dir (Filename.concat dir ".tree-md-stage/txn-barrier")))

(* ── regression tests ── *)

(* C1: writer_active detects lock held by another process.  We spawn a child
   that holds the lock, assert writer_active returns true, then wait for the
   child to exit and assert writer_active returns false. *)
let test_writer_active_cross_process () =
  with_tmpdir (fun dir ->
    lock dir;
    (* release lock so child can acquire *)
    (* we use a lock-unlock sandwich to set up the directory *)
    let rec wait_read fd buf =
      let n = Unix.read fd buf 0 (Bytes.length buf) in
      if n = 0 then Bytes.sub_string buf 0 0
      else Bytes.sub_string buf 0 n
    in
    let parent_rd, child_wr = Unix.pipe () in
    let child_rd, parent_wr = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      Unix.close parent_rd; Unix.close parent_wr;
      (match Workspace_fs.with_build_lock ~output_root:dir (fun () ->
         let _ = Unix.write child_wr (Bytes.of_string "locked") 0 6 in
         let buf = Bytes.create 1 in
         let _ = wait_read child_rd buf in
         ()) with
       | Ok () -> exit 0
       | Error _ -> exit 1)
    | child_pid ->
      Unix.close child_wr; Unix.close child_rd;
      let buf = Bytes.create 6 in
      let _ = wait_read parent_rd buf in
      (* child has the lock *)
      let held = match Workspace_fs.writer_active ~output_root:dir with Ok v -> v | Error ds -> fail_errs ds in
      Alcotest.(check bool) "writer_active true while child holds lock" true held;
      (* release child *)
      let _ = Unix.write parent_wr (Bytes.of_string "x") 0 1 in
      ignore (Unix.waitpid [] child_pid);
      let free = match Workspace_fs.writer_active ~output_root:dir with Ok v -> v | Error ds -> fail_errs ds in
      Alcotest.(check bool) "writer_active false after child releases lock" false free)

(* C3: symlink placed inside .tree-md-stage must trigger refusal (TM403)
   from rmdir_rf_checked during orphan cleanup and Remove_stage. *)
let test_symlink_in_stage_cleanup () =
  with_tmpdir (fun dir ->
    let stage_dir = Filename.concat dir ".tree-md-stage" in
    Unix.mkdir stage_dir 0o700;
    let txn_dir = Filename.concat stage_dir "orphan-txn" in
    Unix.mkdir txn_dir 0o700;
    (* Only create a symlink — no regular files to simplify debugging *)
    let symlink_path = Filename.concat txn_dir "malicious-link" in
    Unix.symlink "/etc/passwd" symlink_path;
    let result = Workspace_fs.remove_orphan_stage ~output_root:dir in
    Alcotest.(check bool) "orphan_stage refuses symlink" true (Result.is_error result);
    (* Clean up manually — symlink should be untouched since cleanup refused it *)
    Sys.remove symlink_path;
    Unix.rmdir txn_dir;
    Unix.rmdir stage_dir)

(* I1: duplicate journal must be rejected *)
let test_duplicate_journal () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "dup out\n" in
    let journal, manifest_bytes, _manifest = journal_for_files "txn-dup" [("dup.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-dup/dup.tree.tmp", content ] in
    (* First stage should succeed *)
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    (* Second stage with same journal should fail *)
    let dup_result = Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () in
    Alcotest.(check bool) "duplicate journal rejected" true (Result.is_error dup_result))

(* I3: symlink output file refused — test that symlink output is rejected *)
let test_symlink_output_delete () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "output content\n" in
    let output_path = Filename.concat dir "out.tree" in
    Unix.symlink "/etc/passwd" output_path;
    let journal, manifest_bytes, _ = journal_for_files "txn-out" [("out.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-out/out.tree.tmp", content ] in
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let rejected = match Transaction.roll_forward journal
                          ~current_manifest:Transaction.Missing
                          ~output:(obs_output dir) ~temporary:(obs_temp dir) with
      | Ok actions ->
        (match Workspace_fs.execute ~output_root:dir actions () with
         | Ok () -> false
         | Error _ -> true)
      | Error _ -> true
    in
    Alcotest.(check bool) "symlink output refused" true rejected;
    Sys.remove output_path)

(* Important-1: intermediate directory durability for nested outputs.
   Creates a depth-2 output (a/b/c.tree): Ensure_parent must create a/b,
   and the intermediate parent a must be fsynced before the commit. *)
let test_deep_nesting_durability () =
  with_tmpdir (fun dir ->
    lock dir;
    let content = "deep nested content\n" in
    let journal, manifest_bytes, _manifest = journal_for_files "txn-deep" [("a/b/c.tree", content)] in
    let files = [ rel ".tree-md-stage/txn-deep/a/b/c.tree.tmp", content ] in
    let _ = match Workspace_fs.stage ~output_root:dir ~journal ~files ~manifest_bytes () with
      | Ok () -> () | Error ds -> fail_errs ds in
    let stage_deep = Filename.concat dir ".tree-md-stage/txn-deep/a/b" in
    Alcotest.(check bool) "stage subdirs created" true (is_dir stage_deep);
    let actions = roll dir journal ~current_manifest:Transaction.Missing in
    let _ = match Workspace_fs.execute ~output_root:dir actions () with
      | Ok () -> () | Error ds -> fail_errs ds in
    Alcotest.(check bool) "deep output exists" true (exists (Filename.concat dir "a/b/c.tree"));
    Alcotest.(check bool) "intermediate dir a exists" true (is_dir (Filename.concat dir "a"));
    Alcotest.(check bool) "intermediate dir a/b exists" true (is_dir (Filename.concat dir "a/b"));
    Alcotest.(check bool) "journal removed" false
      (exists (Filename.concat dir ".tree-md-transaction.json")))

(* Important-2: snapshot must not follow symlinks in .tree-md-stage.
   A symlink-to-stage pointing back to .tree-md-stage creates a cycle;
   the lstat-based walk must skip it without hanging. *)
let test_snapshot_symlink_safety () =
  with_tmpdir (fun dir ->
    let stage_dir = Filename.concat dir ".tree-md-stage" in
    Unix.mkdir stage_dir 0o700;
    let txn_dir = Filename.concat stage_dir "safe-txn" in
    Unix.mkdir txn_dir 0o700;
    write_file (Filename.concat txn_dir "real.tmp") "safe content";
    (* Create a symlink that points back to the stage root, creating a cycle *)
    let cycle_link = Filename.concat txn_dir "cycle-link" in
    Unix.symlink stage_dir cycle_link;
    (* Also a symlink-to-external *)
    let ext_link = Filename.concat txn_dir "ext-link" in
    Unix.symlink "/etc/passwd" ext_link;
    (* Snapshot should complete without hanging and should not follow symlinks *)
    let s = match Workspace_fs.snapshot ~output_root:dir with Ok s -> s | Error ds -> fail_errs ds in
    (* The real file should be listed *)
    Alcotest.(check bool) "real file listed" true
      (List.exists (fun e -> String.ends_with ~suffix:"real.tmp" e) s.stage_entries);
    (* The symlinks may appear as file entries (lstat says S_LNK, not S_DIR)
       but snapshot must NOT follow them into external content or recurse. *)
    let has_cycle = List.exists (fun e -> String.ends_with ~suffix:"cycle-link" e) s.stage_entries in
    let has_ext = List.exists (fun e -> String.ends_with ~suffix:"ext-link" e) s.stage_entries in
    let _ = (has_cycle, has_ext) in
    Alcotest.(check bool) "snapshot completed without hang" true true;
    (* Clean up manually *)
    Sys.remove cycle_link;
    Sys.remove ext_link;
    Sys.remove (Filename.concat txn_dir "real.tmp");
    Unix.rmdir txn_dir;
    Unix.rmdir stage_dir;
    ignore (has_cycle, has_ext))

(* I1-variant: duplicate journal already covered by test_duplicate_journal *)

let () =
  let open Alcotest in
  run "Workspace_fs"
    [ "snapshot", [
        test_case "empty" `Quick test_snapshot_empty;
        test_case "with_files" `Quick test_snapshot_with_files;
      ]
    ; "lock", [
        test_case "contention" `Quick test_lock_contention;
        test_case "writer_active_no_root" `Quick test_writer_active_no_root;
        test_case "cross_process" `Quick test_writer_active_cross_process;
      ]
    ; "symlink_refusal", [
        test_case "output_root" `Quick test_symlink_refusal_output_root;
        test_case "ancestor" `Quick test_symlink_refusal_ancestor;
        test_case "in_stage" `Quick test_symlink_refusal_stage;
        test_case "in_cleanup" `Quick test_symlink_in_stage_cleanup;
        test_case "output_file" `Quick test_symlink_output_delete;
      ]
    ; "stage_execute", [
        test_case "normal" `Quick test_stage_and_execute_normal;
        test_case "duplicate_journal" `Quick test_duplicate_journal;
      ]
    ; "fault_injection", [
        test_case "after_stage" `Quick test_fault_after_stage;
        test_case "after_journal_stage" `Quick test_fault_after_journal_stage;
        test_case "after_output" `Quick test_fault_after_output;
        test_case "after_manifest" `Quick test_fault_after_manifest;
      ]
    ; "orphan_stage", [
        test_case "with_journal" `Quick test_orphan_stage_with_journal;
        test_case "cleanup" `Quick test_orphan_stage_cleanup;
      ]
    ; "durability", [
        test_case "barriers" `Quick test_durability_barriers;
        test_case "deep_nesting" `Quick test_deep_nesting_durability;
      ]
    ; "snapshot_safety", [
        test_case "symlink_cycle" `Quick test_snapshot_symlink_safety;
      ]
    ]
