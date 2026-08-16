type 'a located = { value : 'a; span : Span.t }
type attribution = Tree of string located | Literal of string located

type raw = {
  (* Compile-time only: the tree's identity, which Forester takes from the
     file name of the .tree. Never emitted. *)
  id : string located option;
  date : string located option;
  taxon : string located option;
  authors : attribution list;
  contributors : attribution list;
  tags : string located list;
  meta : (string located * string located) list;
}

type 'inline t = {
  date : string located option;
  taxon : string located option;
  authors : attribution list;
  contributors : attribution list;
  tags : 'inline located list;
  meta : (string located * 'inline located) list;
}

val empty : raw
val valid_id : string -> bool
val parse_attribution : string located -> (attribution, Diagnostic.t) result
val valid_date : string -> bool

val lower_inline_values :
  parse:(string located -> ('inline, Diagnostic.t list) result) ->
  raw -> ('inline t, Diagnostic.t list) result
