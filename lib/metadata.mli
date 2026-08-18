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
(* An address: a stated `id`, a subtree name, a `^anchor`. Forester reads a
   tree's address from a file name it writes itself, so an address is ASCII. *)
val valid_id : string -> bool

(* A reference target: only how a reference spells what it points at. What
   Obsidian writes there is a file name — 日本語のノート, "My Note",
   folder/note — so a target is anything a file name can be, minus the
   characters wiki syntax uses to delimit, and minus the backslash, which is
   never unescaped here. Whether it names anything is settled
   by resolution, and an unresolvable target is still TM202. *)
val valid_link_target : string -> bool
val parse_attribution : string located -> (attribution, Diagnostic.t) result
val valid_date : string -> bool

(* Read the parts tree-md interprets out of the front matter mapping. Keys it
   has no use for are carried, not rejected: mdbase v0.3 §03 makes front matter
   an arbitrary mapping, and an Obsidian vault is full of `aliases`,
   `cssclasses` and `created`, none of which are this compiler's business.

   The one exception is a key within an edit or two of one tree-md does know.
   That is far more likely a typo than a property, and dropping `taxo:` in
   silence would lose a `\taxon{}` with nothing to show for it, so it is
   reported — as a warning, which does not fail the build. *)
val of_yaml :
  ?id_field:string -> Yaml_json.t option -> raw * Diagnostic.t list

(* The key names tree-md interprets, in the two groups the README documents. *)
val reserved_keys : string list
val promoted_meta_keys : string list

val lower_inline_values :
  parse:(string located -> ('inline * Diagnostic.t list, Diagnostic.t list) result) ->
  raw -> ('inline t * Diagnostic.t list, Diagnostic.t list) result
