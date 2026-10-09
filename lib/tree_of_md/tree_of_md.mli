(** JSON-only public forest façade. The legacy Tree_md API remains separate. *)
module Public_forest : module type of Tree_md.Public_forest
