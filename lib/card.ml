(* A link card is what an Obsidian plugin leaves behind after it has fetched a
   page's Open Graph metadata: a fenced block of `key: value` lines naming the
   URL, the title, the description, the host and the images.

   Reading it here rather than fetching the metadata at build time is what
   keeps a build hermetic. The web is not a reproducible input — a page's card
   changes, a host goes away, a runner has no network — and a compiler whose
   output depends on when it ran could not promise the same `.tree` twice. The
   plugin has already asked the web, in the editor, where a person could see
   the answer; a build only reads what was written down.

   `cardlink` is Auto Card Link's fence and `embed` is the one Link Embed and
   Link Cards write. The two agree on every key that matters, so both are
   read, and a key neither this nor any of them means anything by — `parser`,
   `aspectRatio` — is carried nowhere rather than rejected: what a plugin
   writes into its own block is its business. *)

let fences = [ "cardlink"; "embed" ]

let is_card_fence info = List.mem info fences

let error span message =
  [ Diagnostic.make TM108 (Span.Source_span span) message ]

(* A card is one line of text however the page wrote it: a title carrying a
   newline would otherwise put one inside the emitted argument, where it means
   something to Forester's reader rather than to a reader. *)
let one_line value =
  let buf = Buffer.create (String.length value) in
  let space = ref false in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' -> space := true
      | c ->
        if !space && Buffer.length buf > 0 then Buffer.add_char buf ' ';
        space := false;
        Buffer.add_char buf c)
    value;
  Buffer.contents buf

(* YAML resolves an unquoted scalar to whatever it looks like, so a title of
   `2026` arrives as a number. It is still the title. *)
let scalar = function
  | `String value -> Some value
  | `Bool value -> Some (string_of_bool value)
  | `Float value ->
    let rendered = Printf.sprintf "%.17g" value in
    let rendered =
      if Float.is_integer value && Float.abs value < 1e16 then
        Printf.sprintf "%.0f" value
      else rendered
    in
    Some rendered
  | `Null -> None
  | `A _ | `O _ -> None

let is_http url =
  let has prefix =
    String.length url >= String.length prefix
    && String.sub url 0 (String.length prefix) = prefix
  in
  has "http://" || has "https://"

let field fields name =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some value -> (
    match value with
    | `Null -> Ok None
    | (`A _ | `O _) -> Error (name ^ " must be a single line of text")
    | scalar_value -> (
      match scalar scalar_value with
      | None -> Ok None
      | Some text -> (
        match one_line text with "" -> Ok None | text -> Ok (Some text))))

(* A card links to a page and may show a picture of it, so both are absolute
   web URLs — that is what Open Graph carries, and a card is not a place to
   name a tree or a file in the vault. *)
let web_url span ~key value =
  if not (is_http value) then
    Error
      (error span
         ("card " ^ key ^ " must be an http or https URL, not \"" ^ value ^ "\""))
  else
    match Safe_uri.validate Safe_uri.Link span value with
    | Ok validated -> Ok validated.Safe_uri.encoded
    | Error diagnostic -> Error [ diagnostic ]

let ( let* ) = Result.bind

let optional_web_url span ~key = function
  | None -> Ok None
  | Some value ->
    let* encoded = web_url span ~key value in
    Ok (Some encoded)

let of_fields span fields =
  let read name =
    match field fields name with
    | Ok value -> Ok value
    | Error message -> Error (error span ("card " ^ message))
  in
  let* url = read "url" in
  let* title = read "title" in
  let* description = read "description" in
  let* host = read "host" in
  let* image = read "image" in
  let* favicon = read "favicon" in
  match url with
  | None ->
    Error (error span "card block has no `url:`, so there is nothing to link to")
  | Some url ->
    let* card_url = web_url span ~key:"url" url in
    let* card_image = optional_web_url span ~key:"image" image in
    let* card_favicon = optional_web_url span ~key:"favicon" favicon in
    (* A card with nothing written on it is a link with no label. The host,
       then the URL, is what the page is called when it says nothing else. *)
    let card_title =
      match title, host with
      | Some title, _ -> title
      | None, Some host -> host
      | None, None -> url
    in
    Ok
      ({ Ir.card_url;
         card_title;
         card_description = description;
         card_host = host;
         card_image;
         card_favicon }
       : Ir.card)

let parse ~span body =
  match Yaml.of_string body with
  | Error (`Msg message) ->
    Error (error span ("card block is not valid YAML: " ^ message))
  | Ok (`O fields) -> of_fields span fields
  | Ok `Null -> Error (error span "card block is empty")
  | Ok _ ->
    Error (error span "card block must be a mapping of `key: value` lines")
