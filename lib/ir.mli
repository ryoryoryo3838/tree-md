type link = { label : inline list; destination : string; title : string option }
(* [destination] is percent-encoded, which is what a URI must be and what an
   external image's src becomes. [asset_path] is the path as written, which is
   what finds the file on disk and what \route-asset must carry. *)
and image = {
  alt : inline list;
  destination : string;
  asset_path : string;
  (* Obsidian's `![[x.png|300]]` sizes an embed; nothing else sets this. *)
  width : string option;
  title : string option;
}
and inline = { node : inline_node; span : Span.t }
and inline_node =
  | Text of string
  | Emphasis of inline list
  | Strong of inline list
  (* GFM/Obsidian marks that HTML has a standard element for: ~~x~~ is <del>
     and ==x== is <mark>. Forester reaches those through its html namespace,
     so they have a faithful output and no longer need rejecting. *)
  | Strikethrough of inline list
  | Highlight of inline list
  | Code of string
  | Link of link
  | Image of image
  | Wiki_link of { target : string; alias : string option }
  | Wiki_embed of string
  | Math of { tex : string; display : bool }
  (* A footnote reference. [number] is settled by a pass over the whole
     document, because footnotes are numbered by the order they are first
     referred to, not the order they are defined. *)
  | Footnote_ref of { label : string; number : int }
  | Hard_break
  | Soft_break

type list_kind = Unordered | Ordered of int
type table_alignment = Align_none | Align_left | Align_center | Align_right

(* A list item may carry a task marker, which HTML renders as a checkbox. *)
type task_state = Task_unchecked | Task_checked
type code_info = No_info | Language of string
type list_item = {
  item_blocks : block list;
  item_task : task_state option;
  item_span : Span.t;
}
and block = { bnode : block_node; bspan : Span.t }
and block_node =
  | Paragraph of inline list
  | Blockquote of block list
  | List of {
      kind : list_kind;
      tight : bool;
      items : list_item list;
    }
  | Code_block of { info : code_info; code : string }
  (* A GFM table. [alignment] has one entry per column, and every row is padded
     to that width, so emission never has to reason about ragged input. *)
  | Table of {
      alignment : table_alignment list;
      header : inline list list option;
      rows : inline list list list;
    }
  (* An Obsidian callout: a block quote whose first line names a kind.
     `> [!note] Title` carries kind "note" and that title. *)
  | Callout of {
      kind : string;
      folded : bool;
      title : inline list;
      body : block list;
    }
  | Thematic_break
  | Heading of { level : int; title : inline list }
  | Subtree_directive of string
  | Subtree_open of { level : int; id : string option }
  | Subtree_close of int
  | Block_embed of string
  | Display_math of string
  (* Where a footnote was defined. Removed from the flow by the same pass that
     numbers the references, and gathered into [Footnotes]. *)
  | Footnote_def of { label : string; body : block list }
  (* The footnote section, appended once at the end of the document. *)
  | Footnotes of (int * block list) list

type document = {
  metadata : inline list Metadata.t;
  blocks : block list;
  doc_span : Span.t;
}

type reference_kind = Wiki | Embed | Attribution | Markdown_link
type reference = { kind : reference_kind; target : string; span : Span.t }
