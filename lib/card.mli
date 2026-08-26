(* The Open Graph metadata an Obsidian link-card plugin fetched for a URL and
   wrote into the note as a fenced block. Reading what was written down is
   what keeps a build hermetic: the web is not a reproducible input, and the
   plugin has already asked it in the editor, where a person could see the
   answer. *)

(* The fence info strings a card is written under: `cardlink` (Auto Card Link)
   and `embed` (Link Embed, Link Cards). *)
val is_card_fence : string -> bool

val parse : span:Span.t -> string -> (Ir.card, Diagnostic.t list) result
