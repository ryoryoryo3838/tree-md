(* A tree's body is one ordered sequence: a closing subtree directive can end a
   subtree and return to the parent's body, so blocks and subtrees interleave. *)
type content =
  | Block of Ir.block
  | Section of section

(* [title] is [None] for a subtree opened by an <!-- hN --> directive: Forester
   allows a subtree with no \title, which no Markdown heading can express. *)
and section = {
  id : string option;
  definition_span : Span.t option;
  title : Ir.inline list option;
  content : content list;
  span : Span.t;
}

type t = {
  root_id : string;
  title : Ir.inline list;
  metadata : Ir.inline list Metadata.t;
  content : content list;
  span : Span.t;
}

type definition = { id : string; span : Span.t }

val blocks : content list -> Ir.block list
val subtrees : content list -> section list

val build : root_id:string -> Ir.document -> (t, Diagnostic.t list) result

val definitions : t -> definition list
