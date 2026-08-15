type link = { label : inline list; destination : string; title : string option }
and image = { alt : inline list; destination : string; title : string option }
and inline = { node : inline_node; span : Span.t }
and inline_node =
  | Text of string
  | Emphasis of inline list
  | Strong of inline list
  | Code of string
  | Link of link
  | Image of image
  | Wiki_link of { target : string; alias : string option }
  | Wiki_embed of string
  | Math of { tex : string; display : bool }
  | Hard_break
  | Soft_break

type list_kind = Unordered | Ordered of int
type code_info = No_info | Language of string
type list_item = { item_blocks : block list; item_span : Span.t }
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
  | Thematic_break
  | Heading of { level : int; title : inline list }
  | Subtree_directive of string
  | Block_embed of string
  | Display_math of string

type document = {
  metadata : inline list Metadata.t;
  blocks : block list;
  doc_span : Span.t;
}

type reference_kind = Wiki | Embed | Attribution
type reference = { kind : reference_kind; target : string; span : Span.t }
