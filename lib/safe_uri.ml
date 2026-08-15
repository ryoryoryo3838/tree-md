type purpose = Link | Image

let uri_safe c =
  match c with
  | 'A'..'Z' | 'a'..'z' | '0'..'9'
  | '-' | '.' | '_' | '~' | ':' | '/' | '?' | '#' | '['
  | ']' | '@' | '!' | '$' | '&' | '\'' | '(' | ')' | '*'
  | '+' | ',' | ';' | '=' -> true
  | _ -> false

let hex_digit n =
  if n < 10 then Char.chr (Char.code '0' + n)
  else Char.chr (Char.code 'A' + n - 10)

let percent_encode s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    if c <= '\x1F' || c = '\x7F' || not (uri_safe c) then begin
      let code = Char.code c in
      Buffer.add_char buf '%';
      Buffer.add_char buf (hex_digit (code lsr 4));
      Buffer.add_char buf (hex_digit (code land 0xF))
    end else
      Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(* Consume the scheme prefix: [A-Za-z][A-Za-z0-9+.-]*: *)
let parse_scheme s =
  let len = String.length s in
  if len = 0 then None
  else
    let first = s.[0] in
    if not ((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z'))
    then None
    else
      let rec loop i =
        if i >= len then None
        else
          let c = s.[i] in
          if c = ':' then
            let scheme = String.sub s 0 i in
            let rest = String.sub s (i + 1) (len - i - 1) in
            Some (String.lowercase_ascii scheme, rest)
          else if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
               || (c >= '0' && c <= '9') || c = '+' || c = '.' || c = '-'
          then loop (i + 1)
          else None
      in
      loop 1

let allowed_schemes_link = ["http"; "https"; "mailto"]
let allowed_schemes_image = ["http"; "https"]

let schemes_for = function
  | Link -> allowed_schemes_link
  | Image -> allowed_schemes_image

let is_unsafe_scheme scheme schemes =
  not (List.mem scheme schemes)

let validate purpose span s =
  let check_controls () =
    let len = String.length s in
    let rec loop i =
      if i >= len then Ok ()
      else
        let c = s.[i] in
        if c = '\x00' then
          Error (Diagnostic.make TM205 (Span.Source_span span)
                  "URI contains NUL byte")
        else if c <= '\x1F' || c = '\x7F' then
          Error (Diagnostic.make TM205 (Span.Source_span span)
                  "URI contains control character")
        else
          loop (i + 1)
    in
    loop 0
  in
  match check_controls () with
  | Error _ as e -> e
  | Ok () ->
    match parse_scheme s with
    | None ->
      (* No scheme - this is a relative URL or fragment *)
      if String.length s > 0 && s.[0] = '#' then
        (* Fragment: accept for links, reject for images *)
        begin match purpose with
        | Link -> Ok (percent_encode s)
        | Image ->
          Error (Diagnostic.make TM205 (Span.Source_span span)
                  "fragment URI not allowed for images")
        end
      else
        (* Relative path: accept for both purposes *)
        Ok (percent_encode s)
    | Some (scheme, _rest) ->
      let allowed = schemes_for purpose in
      if is_unsafe_scheme scheme allowed then
        Error (Diagnostic.make TM205 (Span.Source_span span)
                ("unsafe URI scheme: " ^ scheme))
      else
        (* Safe scheme; percent-encode unsafe bytes in the full URI *)
        Ok (percent_encode s)
