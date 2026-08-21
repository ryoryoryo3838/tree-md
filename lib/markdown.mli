(* parse_inlines: parse the given Markdown string as inline content.
   [source] is used for path and span resolution.
   [text] is the masked Markdown string (same byte length as original)
   whose byte offsets map directly to the source.
   [base_byte] is an offset added to all byte positions in the result,
   used when [text] is a substring of the original source (e.g. YAML
   scalar values within front matter). For the full document body,
   pass [base_byte = 0]. *)
val parse_inlines :
  Source.t -> string -> base_byte:int ->
  (Ir.inline list * Diagnostic.t list, Diagnostic.t list) result

(* parse: lower a complete Markdown document.
   [source] is the original source file.
   [masked_markdown] is the Markdown body with YAML front matter masked.
   [raw_metadata] is the parsed raw front matter metadata.
   Returns a complete [Ir.document] or diagnostics. *)
val parse :
  Source.t -> masked_markdown:string -> Metadata.raw ->
  (Ir.document * Diagnostic.t list, Diagnostic.t list) result
