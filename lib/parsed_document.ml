type local_asset = { destination : string; span : Span.t }

type t = {
  outline : Outline.t;
  definitions : Outline.definition list;
  references : Ir.reference list;
  local_assets : local_asset list;
}
