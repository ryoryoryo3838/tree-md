open Tree_md

(* Unit tests for the CLI exit-code mapping and the top-level exception
   filter (Cli.exit_code and Cli.For_test.render_unexpected). *)

let str_contains s sub =
  let len = String.length s in
  let sublen = String.length sub in
  let rec loop i =
    if i > len - sublen then false
    else if String.sub s i sublen = sub then true
    else loop (i + 1)
  in
  sublen <= len && loop 0

let zero_summary : Workspace.summary =
  { created = 0; replaced = 0; deleted = 0; unchanged = 0 }

let result_of codes =
  { Workspace.summary = zero_summary;
    minted = [];
    diagnostics =
      List.map
        (fun code ->
          Diagnostic.make code (Span.Path "fixture.tree.md") "test message")
        codes }

(* ── exit code mapping ── *)

let test_exit_code_success () =
  Alcotest.(check int) "no diagnostics exits 0" 0
    (Cli.exit_code (result_of []))

let test_exit_code_source () =
  Alcotest.(check int) "source diagnostic exits 1" 1
    (Cli.exit_code (result_of [ Diagnostic.TM003 ]))

let test_exit_code_semantic () =
  Alcotest.(check int) "semantic diagnostic exits 1" 1
    (Cli.exit_code (result_of [ Diagnostic.TM202 ]))

let test_exit_code_state () =
  Alcotest.(check int) "generated-state diagnostic exits 1" 1
    (Cli.exit_code (result_of [ Diagnostic.TM301 ]))

let test_exit_code_config () =
  Alcotest.(check int) "configuration diagnostic exits 2" 2
    (Cli.exit_code (result_of [ Diagnostic.TM401 ]))

let test_exit_code_manifest () =
  Alcotest.(check int) "manifest diagnostic exits 2" 2
    (Cli.exit_code (result_of [ Diagnostic.TM402 ]))

let test_exit_code_journal () =
  Alcotest.(check int) "journal diagnostic exits 2" 2
    (Cli.exit_code (result_of [ Diagnostic.TM403 ]))

let test_exit_code_io () =
  Alcotest.(check int) "I/O diagnostic exits 2" 2
    (Cli.exit_code (result_of [ Diagnostic.TM404 ]))

let test_exit_code_internal () =
  Alcotest.(check int) "internal diagnostic exits 2" 2
    (Cli.exit_code (result_of [ Diagnostic.TM500 ]))

let test_exit_code_worst_wins () =
  Alcotest.(check int) "mixed diagnostics exit worst (2)" 2
    (Cli.exit_code (result_of [ Diagnostic.TM101; Diagnostic.TM404 ]))

let test_exit_code_all_class_one () =
  let codes =
    [ Diagnostic.TM001; Diagnostic.TM002; Diagnostic.TM003
    ; Diagnostic.TM101; Diagnostic.TM102; Diagnostic.TM103
    ; Diagnostic.TM104; Diagnostic.TM105; Diagnostic.TM106
    ; Diagnostic.TM107
    ; Diagnostic.TM201; Diagnostic.TM202; Diagnostic.TM203
    ; Diagnostic.TM204; Diagnostic.TM205
    ; Diagnostic.TM301; Diagnostic.TM302; Diagnostic.TM303
    ; Diagnostic.TM304; Diagnostic.TM305; Diagnostic.TM306 ]
  in
  Alcotest.(check int) "every source/semantic/state code exits 1" 1
    (Cli.exit_code (result_of codes))

let test_exit_code_all_class_two () =
  let codes =
    [ Diagnostic.TM401; Diagnostic.TM402; Diagnostic.TM403
    ; Diagnostic.TM404; Diagnostic.TM500 ]
  in
  Alcotest.(check int) "every config/manifest/journal/I/O/internal code exits 2" 2
    (Cli.exit_code (result_of codes))

(* ── top-level exception filter ── *)

let captured_backtrace () =
  try raise Exit with Exit -> Printexc.get_raw_backtrace ()

let test_render_unexpected_hides_backtrace () =
  let message, code =
    Cli.For_test.render_unexpected ~backtrace_enabled:false Exit
      (captured_backtrace ())
  in
  Alcotest.(check int) "exit code 2" 2 code;
  Alcotest.(check bool) "message names the exception" true
    (str_contains message "Exit");
  Alcotest.(check bool) "no backtrace section without TREE_MD_BACKTRACE" false
    (str_contains message "backtrace:")

let test_render_unexpected_shows_backtrace () =
  let message, code =
    Cli.For_test.render_unexpected ~backtrace_enabled:true Exit
      (captured_backtrace ())
  in
  Alcotest.(check int) "exit code 2" 2 code;
  Alcotest.(check bool) "backtrace section present" true
    (str_contains message "backtrace:")

let test_render_unexpected_reraises_out_of_memory () =
  Alcotest.check_raises "Out_of_memory is reraised" Out_of_memory (fun () ->
    ignore
      (Cli.For_test.render_unexpected ~backtrace_enabled:false Out_of_memory
         (Printexc.get_raw_backtrace ())))

let test_render_unexpected_reraises_sys_break () =
  Alcotest.check_raises "Sys.Break is reraised" Sys.Break (fun () ->
    ignore
      (Cli.For_test.render_unexpected ~backtrace_enabled:false Sys.Break
         (Printexc.get_raw_backtrace ())))

let () =
  Alcotest.run "tree-md CLI"
    [ ( "exit codes"
      , [ Alcotest.test_case "success" `Quick test_exit_code_success
        ; Alcotest.test_case "source" `Quick test_exit_code_source
        ; Alcotest.test_case "semantic" `Quick test_exit_code_semantic
        ; Alcotest.test_case "state" `Quick test_exit_code_state
        ; Alcotest.test_case "config" `Quick test_exit_code_config
        ; Alcotest.test_case "manifest" `Quick test_exit_code_manifest
        ; Alcotest.test_case "journal" `Quick test_exit_code_journal
        ; Alcotest.test_case "io" `Quick test_exit_code_io
        ; Alcotest.test_case "internal" `Quick test_exit_code_internal
        ; Alcotest.test_case "worst wins" `Quick test_exit_code_worst_wins
        ; Alcotest.test_case "all class one" `Quick
            test_exit_code_all_class_one
        ; Alcotest.test_case "all class two" `Quick
            test_exit_code_all_class_two
        ] )
    ; ( "exception filter"
      , [ Alcotest.test_case "hides backtrace by default" `Quick
            test_render_unexpected_hides_backtrace
        ; Alcotest.test_case "shows backtrace when enabled" `Quick
            test_render_unexpected_shows_backtrace
        ; Alcotest.test_case "reraises Out_of_memory" `Quick
            test_render_unexpected_reraises_out_of_memory
        ; Alcotest.test_case "reraises Sys.Break" `Quick
            test_render_unexpected_reraises_sys_break
        ] )
    ]
