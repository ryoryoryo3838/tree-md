open Cmdliner
module Public_forest = Tree_of_md.Public_forest

let run input output =
  match Public_forest.convert_file ~input ~out_dir:output with
  | Error e -> prerr_endline (Public_forest.error_code e); 1
  | Ok n -> Printf.printf "PF_OK %d\n%!" n; 0

let snapshot = Arg.(required & opt (some string) None &
  info ["public-forest"] ~docv:"INPUT" ~doc:"Approved public-v2 JSON snapshot; no other inputs are read.")
let destination = Arg.(required & opt (some string) None &
  info ["out-dir"] ~docv:"OUTPUT" ~doc:"New or empty directory for flat .tree roots.")
let command = Cmd.v
  (Cmd.info "tree_of_md" ~doc:"Convert forester-public-v2 JSON into native Forester source.")
  Term.(const run $ snapshot $ destination)

let () =
  let private_errors = Format.make_formatter (fun _ _ _ -> ()) (fun () -> ()) in
  let status = match Cmd.eval_value ~err:private_errors command with
    | Ok (`Ok status) -> status
    | Ok (`Help | `Version) -> 0
    | Error (`Parse | `Term) -> prerr_endline "PF_ARGUMENTS"; 2
    | Error `Exn -> prerr_endline "PF_INTERNAL"; 1 in
  exit status
