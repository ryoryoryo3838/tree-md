type t = {
  path : string;
  text : string;
  char_offsets : int array;
  line_starts : int array;
}

type utf8_error = { byte : int }

let codepoint_byte_length first_byte =
  if first_byte land 0x80 = 0 then 1
  else if first_byte land 0xE0 = 0xC0 then 2
  else if first_byte land 0xF0 = 0xE0 then 3
  else if first_byte land 0xF8 = 0xF0 then 4
  else 0

let is_continuation b = b land 0xC0 = 0x80

let validate_utf8 s =
  let len = String.length s in
  let rec loop i =
    if i >= len then Ok ()
    else
      let b = Char.code s.[i] in
      let clen = codepoint_byte_length b in
      if clen = 0 then Error { byte = i }
      else if i + clen > len then Error { byte = i }
      else
        let cp =
          match clen with
          | 1 -> Ok b
          | 2 ->
            let b1 = Char.code s.[i+1] in
            if not (is_continuation b1) then Error { byte = i }
            else
              let cp = ((b land 0x1F) lsl 6) lor (b1 land 0x3F) in
              if cp < 0x80 then Error { byte = i }
              else Ok cp
          | 3 ->
            let b1 = Char.code s.[i+1] in
            let b2 = Char.code s.[i+2] in
            if not (is_continuation b1) || not (is_continuation b2) then
              Error { byte = i }
            else
              let cp =
                ((b land 0x0F) lsl 12) lor
                ((b1 land 0x3F) lsl 6) lor
                (b2 land 0x3F)
              in
              if cp < 0x800 then Error { byte = i }
              else if cp >= 0xD800 && cp <= 0xDFFF then Error { byte = i }
              else Ok cp
          | 4 ->
            let b1 = Char.code s.[i+1] in
            let b2 = Char.code s.[i+2] in
            let b3 = Char.code s.[i+3] in
            if not (is_continuation b1) || not (is_continuation b2)
               || not (is_continuation b3)
            then Error { byte = i }
            else
              let cp =
                ((b land 0x07) lsl 18) lor
                ((b1 land 0x3F) lsl 12) lor
                ((b2 land 0x3F) lsl 6) lor
                (b3 land 0x3F)
              in
              if cp < 0x10000 then Error { byte = i }
              else if cp > 0x10FFFF then Error { byte = i }
              else Ok cp
          | _ -> Error { byte = i }
        in
        match cp with
        | Error _ as e -> e
        | Ok _ -> loop (i + clen)
  in
  loop 0

let build_index s =
  let len = String.length s in
  let char_offsets = ref [] in
  let line_starts = ref [0] in
  let rec loop i =
    if i >= len then ()
    else
      let b = Char.code s.[i] in
      let clen = codepoint_byte_length b in
      char_offsets := i :: !char_offsets;
      if clen >= 1 && clen <= 4 then (
        let ch = s.[i] in
        let next_i = i + clen in
        if ch = '\r' then (
          if next_i < len && s.[next_i] = '\n' then (
            let lf_byte = next_i in
            char_offsets := lf_byte :: !char_offsets;
            line_starts := (lf_byte + 1) :: !line_starts;
            loop (lf_byte + 1)
          ) else (
            line_starts := next_i :: !line_starts;
            loop next_i
          )
        ) else if ch = '\n' then (
          line_starts := next_i :: !line_starts;
          loop next_i
        ) else
          loop next_i
      )
  in
  loop 0;
  let offsets_sorted = Array.of_list (List.rev !char_offsets) in
  let lines_sorted = Array.of_list (List.rev !line_starts) in
  (offsets_sorted, lines_sorted)

let of_string ~path s =
  match validate_utf8 s with
  | Error e -> Error e
  | Ok () ->
    let char_offsets, line_starts = build_index s in
    Ok { path; text = s; char_offsets; line_starts }

let path t = t.path
let text t = t.text
let length t = String.length t.text

let span t ~start_byte ~end_byte =
  Span.make ~path:t.path ~start_byte ~end_byte

let slice t s =
  if s.Span.start_byte < 0 || s.Span.end_byte > String.length t.text then
    Error "span out of bounds"
  else
    Ok (String.sub t.text s.Span.start_byte
          (s.Span.end_byte - s.Span.start_byte))

let display_cols_between t ~start_byte ~end_byte =
  let rec loop i acc =
    if i >= end_byte then acc
    else
      let b = Char.code t.text.[i] in
      let clen = codepoint_byte_length b in
      if t.text.[i] = '\t' then
        loop (i + 1) (acc + (4 - (acc mod 4)))
      else if clen >= 1 && clen <= 4 then
        loop (i + clen) (acc + 1)
      else
        loop (i + 1) (acc + 1)
  in
  loop start_byte 0

let line_col t ~byte =
  if byte < 0 || byte > String.length t.text then
    Error "byte out of range"
  else if byte = String.length t.text then
    Error "byte points past end"
  else
    let line =
      let rec find i =
        if i >= Array.length t.line_starts then Array.length t.line_starts - 1
        else if t.line_starts.(i) > byte then i - 1
        else find (i + 1)
      in
      find 0 + 1
    in
    let line_start = t.line_starts.(line - 1) in
    let col_chars =
      let rec count i acc =
        if i < Array.length t.char_offsets
           && t.char_offsets.(i) < byte then
          count (i + 1) (acc + 1)
        else acc
      in
      count 0 0
    in
    let chars_before_line =
      let rec count i acc =
        if i < Array.length t.char_offsets
           && t.char_offsets.(i) < line_start then
          count (i + 1) (acc + 1)
        else acc
      in
      count 0 0
    in
    let col = col_chars - chars_before_line + 1 in
    Ok (line, col)

let character_to_byte t ~character =
  if character >= 0 && character < Array.length t.char_offsets then
    Some t.char_offsets.(character)
  else
    None

let excerpt t s =
  if s.Span.start_byte < 0 || s.Span.end_byte > String.length t.text then
    Error "span out of bounds"
  else
    let line_start =
      let rec find i =
        if i >= Array.length t.line_starts then
          Array.length t.line_starts - 1
        else if t.line_starts.(i) > s.Span.start_byte then i - 1
        else find (i + 1)
      in
      find 0
    in
    let line_end =
      let rec find i =
        if i >= Array.length t.line_starts then
          Array.length t.line_starts - 1
        else if t.line_starts.(i) > s.Span.end_byte then i - 1
        else find (i + 1)
      in
      find 0
    in
    let excerpt_start = t.line_starts.(line_start) in
    let excerpt_end =
      if line_end + 1 < Array.length t.line_starts then
        t.line_starts.(line_end + 1)
      else
        String.length t.text
    in
    let excerpt_text =
      String.sub t.text excerpt_start (excerpt_end - excerpt_start)
    in
    let trimmed =
      if excerpt_text <> "" && excerpt_text.[String.length excerpt_text - 1] = '\n' then
        String.sub excerpt_text 0 (String.length excerpt_text - 1)
      else
        excerpt_text
    in
    let marker =
      let prefix_cols = display_cols_between t ~start_byte:excerpt_start ~end_byte:s.Span.start_byte in
      let span_cols = display_cols_between t ~start_byte:s.Span.start_byte ~end_byte:s.Span.end_byte in
      let span_display_len = max 1 span_cols in
      let prefix = String.make prefix_cols ' ' in
      let underline = String.make span_display_len '^' in
      prefix ^ underline
    in
    Ok (trimmed, marker)
