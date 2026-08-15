type section = {
  id : string option;
  definition_span : Span.t option;
  title : Ir.inline list;
  body : Ir.block list;
  children : section list;
  span : Span.t;
}

type t = {
  root_id : string;
  title : Ir.inline list;
  metadata : Ir.inline list Metadata.t;
  body : Ir.block list;
  sections : section list;
  span : Span.t;
}

type definition = { id : string; span : Span.t }

val build : root_id:string -> Ir.document -> (t, Diagnostic.t list) result

val definitions : t -> definition list
