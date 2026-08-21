open Tree_md

(* End-to-end workspace lifecycle tests. Every test copies the reviewed
   workspaces/clean fixture into a runtime temp directory and drives the
   read-only check and transactional build workflows through that copy, so
   no test writes inside the repository. *)

let golden_source = "---\nid: index\n---\n\n# Index\n\nIndex body text.\n"
let golden_output = "\\title{Index}\n\\p{Index body text.}\n"
let golden_sha256 = Digestif.SHA256.to_hex (Digestif.SHA256.digest_string golden_output)

(* ── helpers ── *)

(* Resolved, because the workspace refuses an output root reached through a
   symbolic link and macOS puts $TMPDIR under /var, which is a link to
   /private/var. Every path here would carry that link and every test that
   writes would fail for a reason that has nothing to do with what it tests. *)
let tmpdir () =
  let name = Filename.temp_file "tree-md-ws-" "" in
  Unix.unlink name;
  Unix.mkdir name 0o700;
  Unix.realpath name

let rec rm_rf path =
  try
    let st = Unix.lstat path in
    match st.Unix.st_kind with
    | Unix.S_LNK -> Sys.remove path
    | Unix.S_DIR ->
      Array.iter (fun entry ->
        if entry <> "." && entry <> ".." then rm_rf (Filename.concat path entry))
        (Sys.readdir path);
      Unix.rmdir path
    | _ -> Sys.remove path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_tmpdir f =
  let dir = tmpdir () in
  Fun.protect ~finally:(fun () -> rm_rf dir) (fun () -> f dir)

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

let exists path = Sys.file_exists path
let is_dir path = try Sys.is_directory path with Sys_error _ -> false

let ensure_dir path =
  if not (Sys.file_exists path) then Unix.mkdir path 0o700

let errs ds = String.concat "; " (List.map (fun d -> d.Diagnostic.message) ds)
let fail_errs ds = Alcotest.fail (errs ds)

(* Fixture resolution: tests run in the dune sandbox with fixtures copied
   next to the executable; fall back to the source tree build root. *)
let resolve_fixture_path relative =
  let sandbox_path = Filename.concat "fixtures" relative in
  if Sys.file_exists sandbox_path then sandbox_path
  else
    let executable_directory = Filename.dirname (Unix.realpath Sys.executable_name) in
    let build_root =
      executable_directory |> Filename.dirname |> Filename.dirname
      |> Filename.dirname |> Filename.dirname |> Filename.dirname
    in
    Filename.concat build_root ("tools/tree-md/test/fixtures/" ^ relative)

(* Recursive copy that preserves regular files and directories only. Uses
   stat (following symlinks) because dune's test sandbox materializes
   source_tree fixture files as symlinks into _build. *)
let rec cp_r src dst =
  match (Unix.stat src).Unix.st_kind with
  | Unix.S_DIR ->
    Unix.mkdir dst 0o700;
    Array.iter (fun name ->
      if name <> "." && name <> ".." then
        cp_r (Filename.concat src name) (Filename.concat dst name))
      (Sys.readdir src)
  | Unix.S_REG ->
    let content = read_file src in
    write_file dst content
  | _ -> ()

let with_workspace f =
  with_tmpdir (fun dir ->
    let ws = Filename.concat dir "ws" in
    cp_r (resolve_fixture_path "workspaces/clean") ws;
    f ws)

let config_path ws = Filename.concat ws "tree-md.toml"
let output_root ws = Filename.concat ws "generated"
let output_file ws = Filename.concat (output_root ws) "index.tree"
let manifest_file ws = Filename.concat (output_root ws) ".tree-md-manifest.json"
let journal_file ws = Filename.concat (output_root ws) ".tree-md-transaction.json"
let stage_dir ws = Filename.concat (output_root ws) ".tree-md-stage"

let codes (r : Workspace.result) =
  List.map (fun d -> Diagnostic.code_string d.Diagnostic.code) r.diagnostics

let counts (r : Workspace.result) =
  [ r.summary.created; r.summary.replaced; r.summary.deleted; r.summary.unchanged ]

let expect_ok name (r : Workspace.result) =
  Alcotest.(check (list string)) (name ^ ": no diagnostics") [] (codes r);
  r

let snapshot ws =
  match Workspace_fs.snapshot ~output_root:(output_root ws) with
  | Ok s -> s
  | Error ds -> fail_errs ds

(* The reserved .tree-md-stage base directory legitimately persists (empty)
   after a successful build; stage_entries reports its content. *)
let stage_entries ws = (snapshot ws).Workspace_fs.stage_entries

let check_snapshots_equal name before after =
  Alcotest.(check (option string)) (name ^ ": manifest unchanged")
    before.Workspace_fs.manifest after.Workspace_fs.manifest;
  Alcotest.(check (option string)) (name ^ ": journal unchanged")
    before.Workspace_fs.journal after.Workspace_fs.journal;
  Alcotest.(check (list string)) (name ^ ": stage unchanged")
    before.Workspace_fs.stage_entries after.Workspace_fs.stage_entries

let decode_manifest ws =
  let path = manifest_file ws in
  match Manifest.decode ~path (read_file path) with
  | Ok m -> m
  | Error ds -> fail_errs ds

(* ── check lifecycle ── *)

let test_check_first_missing_no_writes () =
  with_workspace (fun ws ->
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM301 missing output" ["TM301"] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    Alcotest.(check bool) "output root not created" false (exists (output_root ws));
    Alcotest.(check bool) "no lock file created" false
      (exists (Filename.concat (output_root ws) ".tree-md.lock")))

let test_check_clean_silent_identical_snapshots () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    let before = snapshot ws in
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "clean check silent" [] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    let after = snapshot ws in
    check_snapshots_equal "clean check" before after)

let test_check_missing_output () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    Sys.remove (output_file ws);
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM301 missing output" ["TM301"] (codes r);
    Alcotest.(check (list string)) "message names output path" [ output_file ws ]
      (List.map (fun d -> match d.Diagnostic.primary with
         | Span.Path p -> p
         | _ -> "") r.diagnostics))

let test_check_modified_output () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (output_file ws) "tampered\n";
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM302 modified output" ["TM302"] (codes r))

let test_check_stale_output () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    Sys.remove (Filename.concat ws "trees-md/index.tree.md");
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM303 stale output" ["TM303"] (codes r))

let test_check_unknown_collision () =
  with_workspace (fun ws ->
    ensure_dir (output_root ws);
    write_file (output_file ws) "unknown\n";
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM304 unknown collision" ["TM304"] (codes r);
    Alcotest.(check string) "unknown file untouched" "unknown\n"
      (read_file (output_file ws)))

let test_check_malformed_manifest () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (manifest_file ws) "{ not json";
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM402 invalid manifest" ["TM402"] (codes r))

let test_check_orphan_stage () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    ensure_dir (stage_dir ws);
    write_file (Filename.concat (stage_dir ws) "orphan.tmp") "junk";
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM306 orphan stage" ["TM306"] (codes r);
    Alcotest.(check bool) "stage preserved by check" true
      (exists (Filename.concat (stage_dir ws) "orphan.tmp")))

let test_check_incomplete_transaction () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (journal_file ws) "{}";
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM305 incomplete transaction" ["TM305"] (codes r))

let test_check_source_error_reports_only_source () =
  with_workspace (fun ws ->
    write_file (Filename.concat ws "trees-md/index.tree.md")
      (golden_source ^ "\n[[ghost]]\n");
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM202 only" ["TM202"] (codes r);
    Alcotest.(check bool) "no writes" false (exists (output_root ws)))

let test_check_config_error () =
  with_workspace (fun ws ->
    write_file (config_path ws)
      (read_file (config_path ws) ^ "\nunknown_key = 1\n");
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM401 config error" ["TM401"] (codes r);
    Alcotest.(check bool) "no writes" false (exists (output_root ws)))

(* ── check concurrency ── *)

let wait_read fd buf =
  let rec loop offset =
    let n = Unix.read fd buf offset (Bytes.length buf - offset) in
    if n = 0 then Bytes.sub_string buf 0 offset
    else if offset + n = Bytes.length buf then Bytes.sub_string buf 0 (offset + n)
    else loop (offset + n)
  in
  loop 0

(* C1: check detects an active writer in another process (TM404) without
   writing any compiler state. *)
let test_check_active_writer () =
  with_workspace (fun ws ->
    let parent_rd, child_wr = Unix.pipe () in
    let child_rd, parent_wr = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      Unix.close parent_rd;
      Unix.close parent_wr;
      (match
         Workspace_fs.with_build_lock ~output_root:(output_root ws) (fun () ->
           let _ = Unix.write child_wr (Bytes.of_string "locked") 0 6 in
           let buf = Bytes.create 1 in
           let _ = Unix.read child_rd buf 0 1 in
           ())
       with
       | Ok () -> exit 0
       | Error _ -> exit 1)
    | child_pid ->
      Unix.close child_wr;
      Unix.close child_rd;
      let _ = wait_read parent_rd (Bytes.create 6) in
      let r = Workspace.check ~config_path:(config_path ws) in
      Alcotest.(check (list string)) "TM404 active writer" ["TM404"] (codes r);
      Alcotest.(check bool) "check wrote no manifest" false (exists (manifest_file ws));
      Alcotest.(check bool) "check wrote no journal" false (exists (journal_file ws));
      let _ = Unix.write parent_wr (Bytes.of_string "x") 0 1 in
      ignore (Unix.waitpid [] child_pid))

(* ── build lifecycle ── *)

let test_build_first_creates_output_and_manifest () =
  with_workspace (fun ws ->
    let r = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "created 1" [1; 0; 0; 0] (counts r);
    Alcotest.(check bool) "output exists" true (exists (output_file ws));
    Alcotest.(check string) "output bytes" golden_output (read_file (output_file ws));
    Alcotest.(check bool) "manifest exists" true (exists (manifest_file ws));
    let m = decode_manifest ws in
    Alcotest.(check int) "one manifest entry" 1 (List.length m.Manifest.files);
    (match m.Manifest.files with
     | [ entry ] ->
       Alcotest.(check string) "entry output" "index.tree"
         (Path_safe.to_string entry.Manifest.output);
       Alcotest.(check string) "entry source" "trees-md/index.tree.md"
         (Path_safe.to_string entry.Manifest.source);
       Alcotest.(check string) "entry sha256" golden_sha256 entry.Manifest.sha256
     | _ -> Alcotest.fail "expected one manifest entry");
    Alcotest.(check bool) "journal absent" false (exists (journal_file ws));
    Alcotest.(check (list string)) "stage empty" [] (stage_entries ws))

let test_build_second_noop () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    let before = snapshot ws in
    let r = expect_ok "second build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "unchanged 1" [0; 0; 0; 1] (counts r);
    let after = snapshot ws in
    check_snapshots_equal "no-op second build" before after)

let test_build_source_edit_replacement () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (Filename.concat ws "trees-md/index.tree.md")
      "---\nid: index\n---\n\n# Index\n\nChanged body.\n";
    let r = expect_ok "replacement build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "replaced 1" [0; 1; 0; 0] (counts r);
    Alcotest.(check string) "output replaced"
      "\\title{Index}\n\\p{Changed body.}\n" (read_file (output_file ws));
    let r = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "check clean after replacement" [] (codes r))

let test_build_source_deletion_stale_cleanup () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    Sys.remove (Filename.concat ws "trees-md/index.tree.md");
    let r = expect_ok "stale cleanup build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "deleted 1" [0; 0; 1; 0] (counts r);
    Alcotest.(check bool) "output removed" false (exists (output_file ws));
    let m = decode_manifest ws in
    Alcotest.(check int) "manifest empty" 0 (List.length m.Manifest.files))

let test_build_missing_output_recreated () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    Sys.remove (output_file ws);
    let r = expect_ok "recreate build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "created 1" [1; 0; 0; 0] (counts r);
    Alcotest.(check string) "output restored" golden_output (read_file (output_file ws)))

(* I1 regression: a nested output whose parent subtree was manually removed
   (rm -rf of generated/a) must be restored; restore creates the output's
   parent directory (with symlink refusal and parent fsync) before the
   rename, mirroring Ensure_parent semantics. *)
let test_build_nested_output_parent_restored () =
  with_workspace (fun ws ->
    let nested_dir = Filename.concat ws "trees-md/a" in
    Unix.mkdir nested_dir 0o700;
    write_file (Filename.concat nested_dir "page.tree.md") "---\nid: page\n---\n\n# Page\n\nNested body.\n";
    let golden_nested = "\\title{Page}\n\\p{Nested body.}\n" in
    let r1 = expect_ok "nested first build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "created 2" [2; 0; 0; 0] (counts r1);
    Alcotest.(check bool) "nested output exists" true
      (exists (Filename.concat (output_root ws) "a/page.tree"));
    (* simulate rm -rf of the whole generated subdirectory *)
    rm_rf (Filename.concat (output_root ws) "a");
    let r2 = expect_ok "nested restore build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "restored 1 unchanged 1" [1; 0; 0; 1] (counts r2);
    Alcotest.(check string) "nested output restored" golden_nested
      (read_file (Filename.concat (output_root ws) "a/page.tree"));
    Alcotest.(check string) "root output untouched" golden_output
      (read_file (output_file ws));
    let r3 = Workspace.check ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "check clean after restore" [] (codes r3))

let test_build_manually_modified_protection () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (output_file ws) "tampered\n";
    let r = Workspace.build ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM302 modified output" ["TM302"] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    Alcotest.(check string) "output untouched" "tampered\n" (read_file (output_file ws));
    Alcotest.(check bool) "no journal left" false (exists (journal_file ws));
    Alcotest.(check (list string)) "no stage content left" [] (stage_entries ws);
    let m = decode_manifest ws in
    Alcotest.(check int) "manifest still valid" 1 (List.length m.Manifest.files))

let test_build_unknown_collision_rejected () =
  with_workspace (fun ws ->
    ensure_dir (output_root ws);
    write_file (output_file ws) "unknown\n";
    let r = Workspace.build ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM304 unknown collision" ["TM304"] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    Alcotest.(check string) "unknown file untouched" "unknown\n" (read_file (output_file ws));
    Alcotest.(check bool) "no manifest written" false (exists (manifest_file ws));
    Alcotest.(check bool) "no journal" false (exists (journal_file ws)))

let test_build_malformed_manifest () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (manifest_file ws) "{ bad";
    let r = Workspace.build ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM402 invalid manifest" ["TM402"] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    Alcotest.(check string) "output untouched" golden_output (read_file (output_file ws));
    Alcotest.(check bool) "no journal" false (exists (journal_file ws)))

let test_build_orphan_stage_removed () =
  with_workspace (fun ws ->
    Unix.mkdir (output_root ws) 0o700;
    Unix.mkdir (stage_dir ws) 0o700;
    write_file (Filename.concat (stage_dir ws) "orphan.tmp") "junk";
    let r = expect_ok "build with orphan stage" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "created 1" [1; 0; 0; 0] (counts r);
    Alcotest.(check (list string)) "orphan stage content removed" [] (stage_entries ws);
    Alcotest.(check string) "output built" golden_output (read_file (output_file ws)))

let test_build_interrupted_journal_roll_forward () =
  with_workspace (fun ws ->
    let gen = output_root ws in
    (* Simulate an interrupted first build: staged temporary output and
       manifest plus the journal, but no final output and no manifest. *)
    let config =
      match Config.load ~path:(config_path ws) with
      | Ok c -> c
      | Error ds -> fail_errs ds
    in
    let discovery =
      match Discovery.scan config with
      | Ok d -> d
      | Error ds -> fail_errs ds
    in
    let expecteds =
      match
        Result.map
          (fun (forest, _) -> forest.Compiler.outputs)
          (Compiler.compile_forest config discovery)
      with
      | Ok e -> e
      | Error ds -> fail_errs ds
    in
    let manifest = Manifest.of_expected expecteds in
    let transaction =
      Transaction.create ~transaction_id:"txn-crash" ~old_manifest:None
        ~new_manifest:manifest (Manifest.diff ~old:None ~next:manifest)
    in
    let files =
      List.filter_map
        (fun (op : Transaction.operation) ->
          match op.Transaction.temporary with
          | Some temp -> Some (temp, golden_output)
          | None -> None)
        transaction.Transaction.operations
    in
    (* Workspace_fs.stage requires the output root to exist, as with_build_lock
       creates it in real builds. *)
    Unix.mkdir gen 0o700;
    (match
       Workspace_fs.stage ~output_root:gen ~journal:transaction ~files
         ~manifest_bytes:(Manifest.encode manifest) ()
     with
     | Ok () -> ()
     | Error ds -> fail_errs ds);
    Alcotest.(check bool) "journal present before build" true (exists (journal_file ws));
    Alcotest.(check bool) "no output before build" false (exists (output_file ws));
    let r = expect_ok "roll-forward build" (Workspace.build ~config_path:(config_path ws)) in
    Alcotest.(check (list int)) "no-op after roll-forward"
      [0; 0; 0; 1] (counts r);
    Alcotest.(check string) "output installed by recovery" golden_output
      (read_file (output_file ws));
    Alcotest.(check bool) "manifest installed" true (exists (manifest_file ws));
    Alcotest.(check bool) "journal removed" false (exists (journal_file ws));
    Alcotest.(check (list string)) "stage content removed" [] (stage_entries ws))

let test_build_source_error_leaves_output_unchanged () =
  with_workspace (fun ws ->
    let _ = expect_ok "first build" (Workspace.build ~config_path:(config_path ws)) in
    write_file (Filename.concat ws "trees-md/index.tree.md")
      (golden_source ^ "\n[[ghost]]\n");
    let r = Workspace.build ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM202 unresolved target" ["TM202"] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    Alcotest.(check string) "output unchanged" golden_output (read_file (output_file ws));
    Alcotest.(check bool) "manifest unchanged" true (exists (manifest_file ws));
    Alcotest.(check bool) "no journal" false (exists (journal_file ws)))

let test_build_config_error_no_writes () =
  with_workspace (fun ws ->
    write_file (config_path ws)
      (read_file (config_path ws) ^ "\nunknown_key = 1\n");
    let r = Workspace.build ~config_path:(config_path ws) in
    Alcotest.(check (list string)) "TM401 config error" ["TM401"] (codes r);
    Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
    Alcotest.(check bool) "no output root created" false (exists (output_root ws)))

(* ── build concurrency ── *)

(* C1: build refuses to start when another process holds the writer lock
   (TM403), without touching any output. *)
let test_build_active_writer () =
  with_workspace (fun ws ->
    let parent_rd, child_wr = Unix.pipe () in
    let child_rd, parent_wr = Unix.pipe () in
    match Unix.fork () with
    | 0 ->
      Unix.close parent_rd;
      Unix.close parent_wr;
      (match
         Workspace_fs.with_build_lock ~output_root:(output_root ws) (fun () ->
           let _ = Unix.write child_wr (Bytes.of_string "locked") 0 6 in
           let buf = Bytes.create 1 in
           let _ = Unix.read child_rd buf 0 1 in
           ())
       with
       | Ok () -> exit 0
       | Error _ -> exit 1)
    | child_pid ->
      Unix.close child_wr;
      Unix.close child_rd;
      let _ = wait_read parent_rd (Bytes.create 6) in
      let r = Workspace.build ~config_path:(config_path ws) in
      Alcotest.(check (list string)) "TM403 lock contention" ["TM403"] (codes r);
      Alcotest.(check (list int)) "summary zeros" [0; 0; 0; 0] (counts r);
      Alcotest.(check bool) "no manifest written" false (exists (manifest_file ws));
      let _ = Unix.write parent_wr (Bytes.of_string "x") 0 1 in
      ignore (Unix.waitpid [] child_pid))

let () =
  let open Alcotest in
  run "Workspace"
    [ "check_lifecycle", [
        test_case "first_check_missing_no_writes" `Quick test_check_first_missing_no_writes;
        test_case "clean_check_silent_identical_snapshots" `Quick test_check_clean_silent_identical_snapshots;
        test_case "missing_output_tm301" `Quick test_check_missing_output;
        test_case "modified_output_tm302" `Quick test_check_modified_output;
        test_case "stale_output_tm303" `Quick test_check_stale_output;
        test_case "unknown_collision_tm304" `Quick test_check_unknown_collision;
        test_case "malformed_manifest_tm402" `Quick test_check_malformed_manifest;
        test_case "orphan_stage_tm306" `Quick test_check_orphan_stage;
        test_case "incomplete_transaction_tm305" `Quick test_check_incomplete_transaction;
        test_case "source_error_reports_only_source" `Quick test_check_source_error_reports_only_source;
        test_case "config_error_tm401" `Quick test_check_config_error;
      ]
    ; "check_concurrency", [
        test_case "active_writer_tm404" `Quick test_check_active_writer;
      ]
    ; "build_lifecycle", [
        test_case "first_build_creates_output_and_manifest" `Quick test_build_first_creates_output_and_manifest;
        test_case "second_build_noop" `Quick test_build_second_noop;
        test_case "source_edit_replacement" `Quick test_build_source_edit_replacement;
        test_case "source_deletion_stale_cleanup" `Quick test_build_source_deletion_stale_cleanup;
        test_case "missing_output_recreated" `Quick test_build_missing_output_recreated;
        test_case "nested_output_parent_restored" `Quick test_build_nested_output_parent_restored;
        test_case "manually_modified_protection" `Quick test_build_manually_modified_protection;
        test_case "unknown_collision_rejected" `Quick test_build_unknown_collision_rejected;
        test_case "malformed_manifest" `Quick test_build_malformed_manifest;
        test_case "orphan_stage_removed" `Quick test_build_orphan_stage_removed;
        test_case "interrupted_journal_roll_forward" `Quick test_build_interrupted_journal_roll_forward;
        test_case "source_error_leaves_output_unchanged" `Quick test_build_source_error_leaves_output_unchanged;
        test_case "config_error_no_writes" `Quick test_build_config_error_no_writes;
      ]
    ; "build_concurrency", [
        test_case "active_writer_tm403" `Quick test_build_active_writer;
      ]
    ]
