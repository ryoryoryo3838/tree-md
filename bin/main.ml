(* Cmdliner hardwires parse errors (missing command, unknown command,
   unknown option) to Cmd.Exit.cli_error (124). The approved CLI
   contract fixes "CLI usage" at exit code 2, so the parse-error status
   is remapped here; every other status (0, 1, 2, and cmdliner's
   internal-error escape for re-raised Out_of_memory/Sys.Break) passes
   through unchanged. *)
let () =
  let code = Cmdliner.Cmd.eval' Tree_md.Cli.command in
  exit (if code = Cmdliner.Cmd.Exit.cli_error then 2 else code)
