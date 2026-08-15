val command : Cmdliner.Cmd.Exit.code Cmdliner.Cmd.t
val exit_code : Workspace.result -> Cmdliner.Cmd.Exit.code

module For_test : sig
  val render_unexpected :
    backtrace_enabled:bool -> exn -> Printexc.raw_backtrace -> string * int
end
