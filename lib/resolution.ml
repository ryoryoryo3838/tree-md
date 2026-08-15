module SpanMap = Map.Make(Span)

type t = {
  assets : string SpanMap.t;
  (* References whose written target differs from the identity it resolved to,
     keyed by the span the reference occupies in the source. *)
  trees : string SpanMap.t;
}

let empty : t = { assets = SpanMap.empty; trees = SpanMap.empty }

let add_asset (span : Span.t) ~routed_path (m : t) : t =
  { m with assets = SpanMap.add span routed_path m.assets }

let asset_route (m : t) (span : Span.t) : string option =
  SpanMap.find_opt span m.assets

let add_tree (span : Span.t) ~id (m : t) : t =
  { m with trees = SpanMap.add span id m.trees }

let tree_id (m : t) (span : Span.t) : string option =
  SpanMap.find_opt span m.trees
