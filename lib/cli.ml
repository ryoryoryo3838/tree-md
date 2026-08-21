(* Cmdliner command terms, exit-code mapping, and the top-level exception
   filter. The approved plan (Task 17) fixes the command interface, the
   exit-code mapping (0 none, 1 source/semantic/state diagnostics, 2
   usage/config/manifest/journal/I/O/internal), and backtrace gating on
   TREE_MD_BACKTRACE=1. *)

let config_default = "./tree-md.toml"

(* Exit class of a stable diagnostic code: 1 for source, semantic,
   forest-consistency, and generated-state codes; 2 for configuration,
   manifest, journal, I/O, and internal codes. *)
let code_class = function
  | Diagnostic.TM401 | Diagnostic.TM402 | Diagnostic.TM403
  | Diagnostic.TM404 | Diagnostic.TM500 -> 2
  | Diagnostic.TM001 | Diagnostic.TM002 | Diagnostic.TM003
  | Diagnostic.TM101 | Diagnostic.TM102 | Diagnostic.TM103
  | Diagnostic.TM104 | Diagnostic.TM105 | Diagnostic.TM106
  | Diagnostic.TM107
  | Diagnostic.TM201 | Diagnostic.TM202 | Diagnostic.TM203
  | Diagnostic.TM204 | Diagnostic.TM205 | Diagnostic.TM206
  | Diagnostic.TM301 | Diagnostic.TM302 | Diagnostic.TM303
  | Diagnostic.TM304 | Diagnostic.TM305 | Diagnostic.TM306 -> 1

(* Only errors decide the exit code. A warning is reported and stepped over,
   so a forest that compiles with warnings still exits 0 and still builds. *)
let exit_code { Workspace.summary = _; diagnostics; _ } =
  List.fold_left
    (fun worst diagnostic ->
      if Diagnostic.is_error diagnostic then
        max worst (code_class diagnostic.Diagnostic.code)
      else worst)
    0 diagnostics

(* ── source map for rendering ──

   Workspace.check/build return only the result record, so the source
   map is derived from the paths the diagnostics themselves reference:
   every file a rendered diagnostic points at is loaded if readable.
   Files that cannot be read (or are not UTF-8) simply fall back to the
   byte-offset location form inside Diagnostic.render. *)

let location_path = function
  | Span.Source_span span -> Some span.Span.path
  | Span.Path _ | Span.No_location -> None

let diagnostic_paths (diagnostic : Diagnostic.t) =
  let add_path acc = function
    | Some path when not (List.mem path acc) -> path :: acc
    | _ -> acc
  in
  let acc = add_path [] (location_path diagnostic.Diagnostic.primary) in
  List.fold_left
    (fun acc { Diagnostic.location; _ } ->
      add_path acc (location_path location))
    acc diagnostic.Diagnostic.secondary

let read_source path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
        match
          Source.of_string ~path
            (really_input_string channel (in_channel_length channel))
        with
        | Ok source -> Some (path, source)
        | Error _ -> None)
  with Sys_error _ -> None

let load_sources diagnostics =
  List.concat_map diagnostic_paths diagnostics
  |> List.sort_uniq String.compare
  |> List.filter_map read_source

let emit_diagnostics diagnostics =
  let sources = load_sources diagnostics in
  List.iter
    (fun diagnostic ->
      output_string stderr (Diagnostic.render ~sources diagnostic))
    (List.sort Diagnostic.compare diagnostics);
  flush stderr

(* ── build summary ── *)

(* An address is a published URL, so a build that invents one says so rather
   than changing where a tree lives in silence. *)
let print_minted (minted : Mint.minted list) =
  List.iter
    (fun (m : Mint.minted) ->
      Printf.printf "minted: %s -> %s\n" m.Mint.path m.Mint.id)
    minted;
  if minted <> [] then flush stdout

let print_build_summary (summary : Workspace.summary) =
  Printf.printf "build: %d created, %d replaced, %d deleted, %d unchanged"
    summary.created summary.replaced summary.deleted summary.unchanged;
  (* Only when a build is selective. A forest that publishes everything has
     nothing to say here, and saying "0 unpublished" would imply it might. *)
  if summary.unpublished > 0 then
    Printf.printf ", %d unpublished" summary.unpublished;
  print_newline ();
  flush stdout

(* ── top-level exception filter ──

   render_unexpected is the filter at the CLI boundary: an unexpected
   exception becomes a one-line message (plus a backtrace section only
   when TREE_MD_BACKTRACE=1) and exit code 2. Out_of_memory and
   Sys.Break are not ordinary diagnostics and are re-raised unchanged. *)

let render_unexpected ~backtrace_enabled exn backtrace =
  match exn with
  | Out_of_memory | Sys.Break -> raise exn
  | _ ->
    let buffer = Buffer.create 128 in
    Buffer.add_string buffer "tree-md: internal error: ";
    Buffer.add_string buffer (Printexc.to_string exn);
    Buffer.add_char buffer '\n';
    if backtrace_enabled then begin
      Buffer.add_string buffer "backtrace:\n";
      Buffer.add_string buffer (Printexc.raw_backtrace_to_string backtrace)
    end;
    (Buffer.contents buffer, 2)

module For_test = struct
  let render_unexpected = render_unexpected
end

let backtrace_enabled () =
  Sys.getenv_opt "TREE_MD_BACKTRACE" = Some "1"

let guard f =
  try f () with
  | exn ->
    let message, code =
      For_test.render_unexpected
        ~backtrace_enabled:(backtrace_enabled ())
        exn (Printexc.get_raw_backtrace ())
    in
    output_string stderr message;
    flush stderr;
    code

(* ── subcommand evaluation ── *)

let run_check config_path =
  guard (fun () ->
    let result = Workspace.check ~config_path in
    emit_diagnostics result.Workspace.diagnostics;
    exit_code result)

let run_build config_path =
  guard (fun () ->
    let result = Workspace.build ~config_path in
    emit_diagnostics result.Workspace.diagnostics;
    (* A build that only warned still ran, so it still reports what it did. *)
    if not (Diagnostic.has_error result.Workspace.diagnostics) then begin
      print_minted result.Workspace.minted;
      print_build_summary result.Workspace.summary
    end;
    exit_code result)

(* ── Cmdliner terms ── *)

let config_arg =
  let doc = "Path to the configuration file (default: ./tree-md.toml)." in
  Cmdliner.Arg.(value & opt string config_default & info ["config"]
                  ~docv:"PATH" ~doc)

let check_command =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "check"
       ~doc:"check the workspace without writing any output")
    Cmdliner.Term.(const run_check $ config_arg)

let build_command =
  Cmdliner.Cmd.v
    (Cmdliner.Cmd.info "build"
       ~doc:"compile the forest and synchronize generated outputs")
    Cmdliner.Term.(const run_build $ config_arg)

let command =
  Cmdliner.Cmd.group
    (Cmdliner.Cmd.info "tree-md"
       ~version:Version.current
       ~doc:"Compile strict Markdown into Forester tree source."
       ~exits:
         [ Cmdliner.Cmd.Exit.info 0
             ~doc:"on success; check also confirms a clean generated state.";
           Cmdliner.Cmd.Exit.info 1
             ~doc:"on source, semantic, forest-consistency, or \
                   generated-state diagnostics.";
           Cmdliner.Cmd.Exit.info 2
             ~doc:"on usage, configuration, manifest, journal, I/O, or \
                   internal failure." ])
    [ build_command; check_command ]
