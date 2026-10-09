open Tree_md

let obj fields = `Assoc fields
let strings xs = `List (List.map (fun x -> `String x) xs)
let markdown text = obj ["kind", `String "markdown"; "text", `String text]
let tree ?id ?(title="Public title") ?(content=[]) () =
  obj ((match id with None -> [] | Some id -> ["id", `String id]) @
    ["title", `String title; "authors", `List []; "dates", `List [];
     "contributors", `List []; "properties", obj []; "citationAuthors", `List [];
     "content", `List content])
let forest trees = obj ["schema", `String "forester-public-v2";
                        "trees", `List trees; "assets", `List []]
let compile json =
  match Public_forest.of_string (Yojson.Safe.to_string json) with
  | Error e -> Alcotest.fail (Public_forest.error_code e)
  | Ok f -> match Public_forest.compile_forest f with
    | Ok files -> files
    | Error e -> Alcotest.fail (Public_forest.error_code e)
let reject json =
  match Public_forest.of_string (Yojson.Safe.to_string json) with
  | Error _ -> ()
  | Ok f -> match Public_forest.compile_forest f with
    | Error _ -> () | Ok _ -> Alcotest.fail "untrusted JSON was accepted"
let test_basic () =
  Alcotest.(check (list (pair string string))) "JSON-only root and Markdown IR"
    ["PUBLICA.tree", "\\title{Public title}\n\\p{Approved \\em{body}.}\n"]
    (compile (forest [tree ~id:"PUBLICA" ~content:[markdown "Approved *body*."] ()]))

let set key value = function
  | `Assoc xs -> obj ((key, value) :: List.remove_assoc key xs)
  | _ -> failwith "fixture object"
let remove key = function `Assoc xs -> obj (List.remove_assoc key xs) | _ -> assert false
let test_schema () =
  let good = tree ~id:"PUBLICA" () in
  let extra obj = set "sourcePath" (`String "PRIVATE_PATH_CANARY") obj in
  List.iter reject
    [extra (forest [good]); forest [extra good];
     set "schema" (`String "forester-public-v1") (forest [good]);
     set "assets" (`List [obj ["path", `String "hidden.png"]]) (forest [good]);
     forest [set "content" (`List [extra (markdown "body")]) good];
     forest [set "authors" (`List [obj ["kind", `String "literal"; "value", `String "A"; "id", `String "X"]]) good];
     forest [set "contributors" (`List [obj ["kind", `String "person"; "id", `String "X"]]) good];
     forest [set "properties" (obj ["publish", strings ["true"]]) good];
     forest [set "properties" (obj ["position", `String "wrong type"]) good];
     forest [set "content" (`List [obj ["kind", `String "transclude"; "id", `String "PUBLICA"; "header", `String "true"; "toc", `Bool true]]) good];
     forest [set "content" (`List [obj ["kind", `String "raw"; "text", `String "body"]]) good];
     forest [tree ()]; forest [set "title" `Null good];
     forest [remove "dates" good];
     obj ["schema", `String "forester-public-v2"; "schema", `String "forester-public-v2";
          "trees", `List [good]; "assets", `List []]]
let test_ids () =
  List.iter (fun id -> reject (forest [tree ~id ()]))
    [""; "."; ".."; "../escape"; "a/b"; "a_b"; "a.b"; "a b"; "日本語"; "a\n"; "\\title{bad}"; "ＡＢＣ"];
  List.iter (fun ids -> reject (forest (List.map (fun id -> tree ~id ()) ids)))
    [["PUBLICA"; "PUBLICA"]; ["PublicA"; "publica"]];
  let bad_child = obj ["kind", `String "subtree"; "tree", tree ~id:"publica" ()] in
  reject (forest [tree ~id:"PUBLICA" ~content:[bad_child] ()]);
  Alcotest.(check string) "original ID spelling" "MiXeD-123.tree"
    (fst (List.hd (compile (forest [tree ~id:"MiXeD-123" ()]))))

let subtree t = obj ["kind", `String "subtree"; "tree", t]
let test_nested () =
  let child = tree ~id:"CHILD" ~title:"Child" ~content:[markdown "child body"] () in
  let anonymous = tree ~title:"Anonymous" ~content:[markdown "anonymous body"] () in
  let parent = tree ~id:"PUBLICA" ~title:"Root"
    ~content:[markdown "before"; subtree child; markdown "between";
              subtree anonymous; markdown "after"] () in
  let island = tree ~id:"ISLAND" ~title:"Island" ~content:[markdown "safe island"] () in
  Alcotest.(check (list (pair string string))) "flat sorted roots, native single definitions"
    ["ISLAND.tree", "\\title{Island}\n\\p{safe island}\n";
     "PUBLICA.tree", "\\title{Root}\n\\p{before}\n\\subtree[CHILD]{\n\\title{Child}\n\\p{child body}\n}\n\\p{between}\n\\subtree{\n\\title{Anonymous}\n\\p{anonymous body}\n}\n\\p{after}\n"]
    (compile (forest [parent; island]))

let literal value = obj ["kind", `String "literal"; "value", `String value]
let attribution id = obj ["kind", `String "tree"; "id", `String id]
let test_metadata () =
  let child = tree ~id:"CHILD" ~title:"Child" ()
    |> set "authors" (`List [literal "Local child"])
    |> set "dates" (strings ["2026-10-10"]) in
  let parent = tree ~id:"PUBLICA" ~title:"100% {literal} \\title{not-executable}" ~content:[subtree child] ()
    |> set "authors" (`List [attribution "PERSON"; literal "Alice {A}"])
    |> set "contributors" (`List [literal "Contributor"])
    |> set "dates" (strings ["2024-02-29"; "2026-10-09"])
    |> set "taxon" (`String "Claim {not macro}")
    |> set "properties" (obj ["institution", strings ["Public school"]; "bibtex", strings ["@book{x}"]])
    |> set "citationAuthors" (strings ["Citation {author}"])
    |> set "publicationYear" (`String "2025") in
  let files = compile (forest [parent; tree ~id:"PERSON" ~title:"Person" ()]) in
  Alcotest.(check string) "literal and relational metadata, local additions only"
    ("\\title{100\\% \\verbFMD|{FMDliteral\\verbFMD|}FMD \\verbFMD|\\FMDtitle\\verbFMD|{FMDnot-executable\\verbFMD|}FMD}\n" ^
     "\\date{2024-02-29}\n\\date{2026-10-09}\n\\taxon{Claim \\verbFMD|{FMDnot macro\\verbFMD|}FMD}\n" ^
     "\\author{PERSON}\n\\author/literal{Alice \\verbFMD|{FMDA\\verbFMD|}FMD}\n\\contributor/literal{Contributor}\n" ^
     "\\meta{bibtex}{@book\\verbFMD|{FMDx\\verbFMD|}FMD}\n\\meta{institution}{Public school}\n" ^
     "\\meta{author}{Citation \\verbFMD|{FMDauthor\\verbFMD|}FMD}\n\\meta{publication-year}{2025}\n" ^
     "\\subtree[CHILD]{\n\\title{Child}\n\\date{2026-10-10}\n\\author/literal{Local child}\n}\n")
    (List.assoc "PUBLICA.tree" files)
let test_metadata_validation () =
  List.iter (fun date -> reject (forest [tree ~id:"PUBLICA" () |> set "dates" (strings [date])]))
    ["2023-02-29"; "2026-13-01"; "2026-00-01"; "2026-10-00"; "0000-01-01";
     "[[2026-10-10]]"; "2026-1-1"; "2026-10-10}\\title{injected}"; "2026-10-10T99:00:00Z"];
  List.iter (fun key -> List.iter (fun value ->
    reject (forest [tree ~id:"PUBLICA" () |> set "properties" (obj [key, strings [value]])]))
    ["javascript:alert(1)"; "data:text/html,hi"; "file:///private"; "//example.test"; "relative/private"])
    ["external"; "slides"; "video"];
  ignore (compile (forest [tree ~id:"PUBLICA" () |> set "properties"
    (obj ["external", strings ["https://example.test/public"]])]))

let transclude ?(header=true) ?(toc=true) id =
  obj ["kind", `String "transclude"; "id", `String id; "header", `Bool header; "toc", `Bool toc]
let test_transclusion () =
  let source = tree ~id:"PUBLICA" ~content:[markdown "See [[ISLAND|Public island]].";
    transclude ~header:false ~toc:false "ISLAND"; transclude "ISLAND";
    transclude ~header:true ~toc:false "ISLAND"; transclude ~header:false ~toc:true "ISLAND"] () in
  Alcotest.(check string) "ID reference plus scoped native placement flags"
    ("\\title{Public title}\n\\p{See [Public island](ISLAND).}\n" ^
     "\\scope{\\put\\transclude/heading{false}\\put\\transclude/toc{false}\\transclude{ISLAND}}\n" ^
     "\\transclude{ISLAND}\n" ^
     "\\scope{\\put\\transclude/heading{true}\\put\\transclude/toc{false}\\transclude{ISLAND}}\n" ^
     "\\scope{\\put\\transclude/heading{false}\\put\\transclude/toc{true}\\transclude{ISLAND}}\n")
    (List.assoc "PUBLICA.tree" (compile (forest [source; tree ~id:"ISLAND" ()])))
let test_graph () =
  List.iter (fun content -> reject (forest [tree ~id:"PUBLICA" ~content ()]))
    [[transclude "MISSING"]; [markdown "[[MISSING|Public label]]"]; [transclude "publica"]];
  List.iter (fun key -> reject (forest [tree ~id:"PUBLICA" () |> set key (`List [attribution "MISSING"])]))
    ["authors"; "contributors"];
  reject (forest [tree ~id:"PUBLICA" ~content:[transclude "PUBLICA"] ()]);
  reject (forest [tree ~id:"PUBLICA" ~content:[transclude "ISLAND"] ();
                  tree ~id:"ISLAND" ~content:[transclude "PUBLICA"] ()]);
  reject (forest [tree ~id:"PUBLICA" ~content:[subtree
    (tree ~id:"CHILD" ~content:[transclude "PUBLICA"] ())] ()]);
  reject (forest [tree ~id:"PUBLICA" ~content:[subtree
    (tree ~content:[transclude "PUBLICA"] ())] ()]);
  ignore (compile (forest [tree ~id:"PUBLICA" ~content:[markdown "[[ISLAND|Island]]"] ();
                          tree ~id:"ISLAND" ~content:[markdown "[[PUBLICA|Root]]"] ()]));
  ignore (compile (forest [tree ~id:"PUBLICA" ~content:[subtree (tree ~id:"CHILD" ()); transclude "CHILD"] ()]))

let with_chunk text = forest [tree ~id:"PUBLICA" ~content:[markdown text] (); tree ~id:"ISLAND" ()]
let test_markdown_boundary () =
  List.iter (fun text -> reject (with_chunk text))
    ["# Unaccounted root"; "## New subtree ^HIDDEN"; "Title\n=====";
     "<!-- h2:HIDDEN -->\nbody"; "<!-- ordinary hidden comment -->"; "a <!-- secret --> b";
     "---\nid: HIDDEN\npublish: true\n---\nbody"; "+++\ntitle = 'HIDDEN'\n+++";
     "<script>alert(1)</script>"; "<div>raw</div>"; "a <b>raw</b> b";
     "\\title{injected}"; "\\{\\subtree[HIDDEN]{private}}"; "#{raw}";
     "%%hidden%%"; "a %%p%%"; "![[ISLAND]]"; "inline ![[ISLAND]] here";
     "[[file#^ISLAND|label]]"; "[[ ISLAND|label]]"; "[[ISLAND |label]]";
     "[[ISLAND|label`]]"; "[[ISLAND|$math$]]"; "[[ISLAND|<img>]]";
     "[[ISLAND|\\title{injected}]]"; "[[ISLAND|a%%secret%%]]";
     "[[ISLAND|label\nbroken]]"; "[[ISLAND|label"; "[[ISLAND|label]]]]";
     "body ^HIDDEN"; "^HIDDEN"; "[unused]: private-file.md";
     "![asset](https://example.test/public.png)"; "[file](../private.md)";
     "```cardlink\nurl: https://example.test/\ntitle: card\n```";
     "$}\\title{injected}{$"; "$\\title{injected}$"; "$\\includegraphics{x}$"]
let test_protected_examples () =
  let text = "`## example ![[MISSING]] %%p%% \\title{x}`\n\n" ^
    "```forester\n<!-- h2:HIDDEN -->\n\\title{example}\n![[MISSING]]\n```\n\n" ^
    "    # indented example\n    ![[MISSING]]\n\n" ^
    "Ordinary $\\frac{a}{b}$ and [[ISLAND|Public island]].\n\n> Plain *quote*.\n\n- a\n- b" in
  let out = List.assoc "PUBLICA.tree" (compile (with_chunk text)) in
  Alcotest.(check bool) "math encoded as inert native verbatim" true
    (String.starts_with ~prefix:"\\title{Public title}" out &&
     let re = Re.compile (Re.str "#{\\verbPFM0|\\frac{a}{b}PFM0}") in Re.execp re out);
  Alcotest.(check bool) "code example cannot define or transclude" false
    (Re.execp (Re.compile (Re.str "\\transclude{MISSING}")) out)

let reject_text ?code text =
  match Public_forest.of_string text with
  | Error error -> Option.iter (fun expected ->
      Alcotest.(check string) "bounded generic error" expected (Public_forest.error_code error)) code
  | Ok f -> match Public_forest.compile_forest f with
    | Error _ when code=None -> () | _ -> Alcotest.fail "non-strict or unbounded JSON accepted"
let test_json_grammar_and_bounds () =
  let empty = "{\"schema\":\"forester-public-v2\",\"trees\":[],\"assets\":[]}" in
  List.iter reject_text [empty ^ "/*comment*/"; "//comment\n" ^ empty;
    "{\"schema\":\"forester-public-v2\",\"trees\":[],\"assets\":[],}";
    "{schema:\"forester-public-v2\",\"trees\":[],\"assets\":[]}";
    empty ^ empty; String.make 1 (Char.chr 255) ^ empty];
  reject_text ~code:"PF_LIMIT" (String.make (8*1024*1024+1) ' ');
  reject_text ~code:"PF_LIMIT" (String.make 129 '[' ^ "null" ^ String.make 129 ']');
  List.iter (fun title -> reject (forest [tree ~id:"PUBLICA" ~title ()]))
    ["bad\000value"; "bad\001value"; "bad\127value"; String.make 1 (Char.chr 255)];
  reject_text "{\"schema\":\"forester-public-v2\",\"trees\":[],\"assets\":[],\"\\u0073chema\":\"forester-public-v2\"}";
  reject_text "{\"schema\":\"forester-public-v2\",\"trees\":[],\"assets\":[],\"x\":\"\\ud800\"}";
  let rec nesting n = if n=0 then tree () else tree ~content:[subtree (nesting (n-1))] () in
  reject_text ~code:"PF_LIMIT" (Yojson.Safe.to_string (forest [set "id" (`String "PUBLICA") (nesting 33)]));
  reject_text ~code:"PF_LIMIT" (Yojson.Safe.to_string (forest [tree ~id:(String.make 251 'A') ()]));
  reject (with_chunk "ordinary\rstandalone CR");
  ignore (compile (with_chunk "ordinary\r\nCRLF"))

let read_text path =
  let ch = open_in_bin path in Fun.protect ~finally:(fun () -> close_in ch)
    (fun () -> really_input_string ch (in_channel_length ch))
let write_text path text =
  let ch = open_out_bin path in Fun.protect ~finally:(fun () -> close_out ch)
    (fun () -> output_string ch text)
let with_temp f =
  let base = match Sys.getenv_opt "TMPDIR" with Some p -> p | None -> Filename.get_temp_dir_name () in
  let path = Filename.temp_file ~temp_dir:base "public-v2-test-" "" in
  Sys.remove path; Unix.mkdir path 0o700;
  let rec clean path =
    match (Unix.lstat path).Unix.st_kind with
    | Unix.S_DIR -> Array.iter (fun n -> clean (Filename.concat path n)) (Sys.readdir path); Unix.rmdir path
    | _ -> Sys.remove path in
  Fun.protect ~finally:(fun () -> clean path) (fun () -> f path)
let cli = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "bin/public_main.exe"
let run_cli args log =
  Sys.command (Filename.quote cli ^ " " ^ String.concat " " (List.map Filename.quote args) ^
    " > " ^ Filename.quote log ^ " 2>&1")
let test_file_api () = with_temp (fun dir ->
  let input = Filename.concat dir "approved.json" and output = Filename.concat dir "trees" in
  write_text input (Yojson.Safe.to_string (forest [tree ~id:"PUBLICA" ()]));
  let before = read_text input in
  (match Tree_of_md.Public_forest.convert_file ~input ~out_dir:output with
   | Ok n -> Alcotest.(check int) "façade writes root count" 1 n
   | Error e -> Alcotest.fail (Public_forest.error_code e));
  Alcotest.(check string) "source unchanged" before (read_text input);
  Alcotest.(check (list string)) "only addressed roots" ["PUBLICA.tree"] (Array.to_list (Sys.readdir output));
  Alcotest.(check string) "actual .tree bytes" "\\title{Public title}\n" (read_text (Filename.concat output "PUBLICA.tree")))
let test_cli () = with_temp (fun dir ->
  let input=Filename.concat dir "approved.json" and output=Filename.concat dir "trees" and log=Filename.concat dir "log" in
  write_text input (Yojson.Safe.to_string (forest [tree ~id:"PUBLICA" ()]));
  Alcotest.(check int) "official tree_of_md CLI" 0
    (run_cli ["--public-forest";input;"--out-dir";output] log);
  Alcotest.(check string) "generic count only" "PF_OK 1\n" (read_text log);
  Alcotest.(check string) "exact route spelling" "\\title{Public title}\n" (read_text (Filename.concat output "PUBLICA.tree"));
  Alcotest.(check int) "input required, no legacy fallback" 2 (run_cli ["--out-dir";output] log);
  Alcotest.(check string) "generic arguments error" "PF_ARGUMENTS\n" (read_text log))

let test_output_namespace () = with_temp (fun dir ->
  let input=Filename.concat dir "approved.json" and log=Filename.concat dir "log" in
  write_text input (Yojson.Safe.to_string (forest [tree ~id:"PUBLICA" ()]));
  let empty=Filename.concat dir "empty" in Unix.mkdir empty 0o700;
  Alcotest.(check int) "existing empty directory" 0 (run_cli ["--public-forest";input;"--out-dir";empty] log);
  let nested=Filename.concat dir "new/parents/trees" in
  Alcotest.(check int) "new output parents" 0 (run_cli ["--public-forest";input;"--out-dir";nested] log);
  let outside=Filename.concat dir "outside" in Unix.mkdir outside 0o700;
  let link=Filename.concat dir "link" in Unix.symlink outside link;
  List.iter (fun out ->
    Alcotest.(check int) "symlink or stale output refuses" 1 (run_cli ["--public-forest";input;"--out-dir";out] log);
    Alcotest.(check string) "generic output code" "PF_OUTPUT\n" (read_text log))
    [link; Filename.concat link "escape"; empty; input; Filename.concat dir "bad/../escape"];
  Alcotest.(check (list string)) "no symlink target writes" [] (Array.to_list (Sys.readdir outside));
  Alcotest.(check bool) "no mkdir before lexical rejection" false (Sys.file_exists (Filename.concat dir "bad"));
  let snapshotlink=Filename.concat dir "snapshotlink.json" in Unix.symlink input snapshotlink;
  let inputdir=Filename.concat dir "inputdir" in Unix.symlink dir inputdir;
  List.iter (fun src ->
    Alcotest.(check int) "no symlink input" 1 (run_cli ["--public-forest";src;"--out-dir";Filename.concat dir "refused"] log);
    Alcotest.(check string) "generic input code" "PF_IO\n" (read_text log))
    [snapshotlink; Filename.concat inputdir "approved.json"])
let test_no_writes_on_rejection () = with_temp (fun dir ->
  let input=Filename.concat dir "private-input-canary.json" and output=Filename.concat dir "no/trees" and log=Filename.concat dir "log" in
  List.iter (fun json ->
    write_text input (Yojson.Safe.to_string json);
    let before=read_text input in
    Alcotest.(check int) "hostile input rejected" 1 (run_cli ["--public-forest";input;"--out-dir";output] log);
    Alcotest.(check bool) "no output parent created" false (Sys.file_exists (Filename.concat dir "no"));
    Alcotest.(check string) "exact source bytes unchanged" before (read_text input);
    Alcotest.(check bool) "no private path or payload in error" false
      (Re.execp (Re.compile (Re.alt [Re.str "private-input-canary";Re.str "PRIVATE_PAYLOAD_CANARY"])) (read_text log)))
    [forest [tree ~id:"PUBLICA" () |> set "privateField" (`String "PRIVATE_PAYLOAD_CANARY")];
     with_chunk "<!-- PRIVATE_PAYLOAD_CANARY -->";
     forest [tree ~id:"PUBLICA" ~content:[transclude "MISSING"] ()];
     forest [tree ~id:"PUBLICA" ~content:[transclude "PUBLICA"] ()]];
  Alcotest.(check int) "unknown option rejected generically" 2
    (run_cli ["--PRIVATE_PAYLOAD_CANARY";input] log);
  Alcotest.(check string) "argument redaction" "PF_ARGUMENTS\n" (read_text log))

let test_literal_entity_labels () =
  let out=List.assoc "PUBLICA.tree" (compile (with_chunk
    "[[ISLAND|A &#91;B&#93; &#92;title{X} &amp;#91;]]")) in
  Alcotest.(check string) "one entity layer decoded; syntax escaped, never activated"
    "\\title{Public title}\n\\p{[A \\verbFMD|[FMDB\\verbFMD|]FMD \\verbFMD|\\FMDtitle\\verbFMD|{FMDX\\verbFMD|}FMD &\\verbFMD|#FMD91;](ISLAND)}\n" out;
  ignore (compile (with_chunk "[ `literal protected example` ["));
  let math=List.assoc "PUBLICA.tree" (compile (with_chunk "$PFM0 + \\frac{a}{b}$")) in
  Alcotest.(check bool) "adaptive math delimiter cannot collide" true
    (Re.execp (Re.compile (Re.str "\\verbPFM1|PFM0 + \\frac{a}{b}PFM1")) math)

let expect_code code json =
  let result = match Public_forest.of_string (Yojson.Safe.to_string json) with
    | Error e -> Error e | Ok f -> Public_forest.compile_forest f in
  match result with
  | Error e -> Alcotest.(check string) "explicit unsupported value" code (Public_forest.error_code e)
  | Ok _ -> Alcotest.fail "unsupported value was accepted"
let identifier_fixture key value =
  forest [tree ~id:"PUBLICA" () |> set "properties" (obj [key, strings [value]])]
let test_identifier_validation () =
  let native = ["doi", "10.0000/Synthetic.a(b)/c:1";
                "orcid", "0000-0000-0000-000X"] in
  List.iter (fun (key, value) ->
    let hosts = if key="doi" then ["doi.org";"www.doi.org";"dx.doi.org"] else ["orcid.org"] in
    let inputs = value :: List.concat_map (fun host ->
      ["https://" ^ host ^ "/" ^ value; "http://" ^ host ^ "/" ^ value]) hosts in
    List.iter (fun input ->
      Alcotest.(check string) "native identifier spelling, exactly one adaptation"
        ("\\title{Public title}\n\\meta{" ^ key ^ "}{" ^ Forester_6.escape_literal value ^ "}\n")
        (List.assoc "PUBLICA.tree" (compile (identifier_fixture key input)))) inputs) native;
  List.iter (fun (key, value) ->
    let host = if key="doi" then "doi.org" else "orcid.org" in
    let url = "https://" ^ host ^ "/" ^ value in
    List.iter (fun input -> expect_code "PF_SCHEMA" (identifier_fixture key input))
      [""; " " ^ value; value ^ " "; url ^ "?q=1"; url ^ "#fragment";
       "https://user@" ^ host ^ "/" ^ value; "https://user:pass@" ^ host ^ "/" ^ value;
       "https://" ^ host ^ ":443/" ^ value; "https://" ^ host ^ ".evil.test/" ^ value;
       "https://evil.test/" ^ value; "https://" ^ host ^ "//" ^ value;
       "https://" ^ host ^ "/https://" ^ host ^ "/" ^ value;
       "https%3A%2F%2F" ^ host ^ "%2F" ^ value; "https://" ^ host ^ "/%31" ^ value;
       "ftp://" ^ host ^ "/" ^ value; "//" ^ host ^ "/" ^ value;
       "HTTPS://" ^ host ^ "/" ^ value; "https://" ^ String.uppercase_ascii host ^ "/" ^ value;
       value ^ "}\\title{injected}"; value ^ "<script>"; value ^ "\nnext"; value ^ "\\path"])
    ["doi", "10.0000/synthetic"; "orcid", "0000-0000-0000-0000"];
  List.iter (fun value -> expect_code "PF_SCHEMA" (identifier_fixture "doi" value))
    ["10.000/suffix";"10.1234567890/suffix";"10.0000/";"11.0000/suffix";
     "doi:10.0000/suffix";"10.0000/suffix%2Fextra";"10.0000/suffix?x";"10.0000/suffix#x"];
  List.iter (fun value -> expect_code "PF_SCHEMA" (identifier_fixture "orcid" value))
    ["0000000000000000";"0000-0000-0000-000x";"0000-0000-000X-0000";
     "0000-0000-0000-00000";"orcid:0000-0000-0000-0000"]

let test_calendar_dates_only () =
  let with_date date = forest [tree ~id:"PUBLICA" () |> set "dates" (strings [date])] in
  List.iter (fun date ->
    Alcotest.(check string) "complete calendar date retained"
      ("\\title{Public title}\n\\date{" ^ date ^ "}\n")
      (List.assoc "PUBLICA.tree" (compile (with_date date))))
    ["0001-01-01";"2000-02-29";"2024-02-29";"2026-10-10";"9999-12-31"];
  let timestamps = ["2026-10-10T12:34:56Z";"2026-10-10T12:34:56+09:00";
                    "2026-10-10T12:34:56-09:00"] in
  List.iter (fun timestamp ->
    Alcotest.(check bool) "legacy timestamp API remains valid" true (Metadata.valid_date timestamp);
    expect_code "PF_DATE" (with_date timestamp)) timestamps;
  List.iter (fun date -> expect_code "PF_DATE" (with_date date))
    ["2026";"2026-10";"2026-1-1";"2026-10-10 ";" 2026-10-10";"2026/10/10";
     "2026-W41-6";"2026-283";"0000-01-01";"1900-02-29";"2026-02-29";
     "2026-04-31";"2026-13-01";"2026-00-01";"2026-10-00";
     "2026-10-10T12:34:56.123Z";"2026-10-10t12:34:56z";"[[2026-10-10]]"]

(* Opt-in acceptance against the pinned native binary, never a .tree-only
   link assertion. An actual producer snapshot can be supplied unchanged. *)
let test_native_identifier_links () =
  match Sys.getenv_opt "PUBLIC_FOREST_TEST_FORESTER" with
  | None -> ()
  | Some forester -> with_temp (fun dir ->
    let input = match Sys.getenv_opt "PUBLIC_FOREST_TEST_FIXTURE" with
      | Some path -> path
      | None ->
        let path = Filename.concat dir "approved.json" in
        write_text path (Yojson.Safe.to_string (forest [tree ~id:"PUBLICA" ();
          tree ~id:"PERSON" () |> set "properties"
            (obj ["orcid", strings ["https://orcid.org/0000-0000-0000-0000"]]);
          tree ~id:"REFERENCE" () |> set "properties"
            (obj ["doi", strings ["https://doi.org/10.0000/synthetic"]])]));
        path in
    let before = read_text input in
    let output = Filename.concat dir "trees" in
    (match Public_forest.convert_file ~input ~out_dir:output with
     | Ok _ -> () | Error e -> Alcotest.fail (Public_forest.error_code e));
    write_text (Filename.concat dir "forest.toml")
      "[forest]\ntrees = [\"trees\"]\nassets = []\nhome = \"PUBLICA\"\nurl = \"https://example.invalid/\"\n";
    let log = Filename.concat dir "native.log" in
    Alcotest.(check int) "real production Forester build" 0
      (Sys.command ("cd " ^ Filename.quote dir ^ " && " ^ Filename.quote forester ^
        " build --no-theme forest.toml > " ^ Filename.quote log ^ " 2>&1"));
    List.iter (fun (id, href) ->
      let html = read_text (Filename.concat dir ("output/" ^ id ^ "/index.html")) in
      Alcotest.(check bool) ("native href for " ^ id) true
        (Re.execp (Re.compile (Re.str ("href=\"" ^ href ^ "\""))) html))
      ["PERSON", "https://orcid.org/0000-0000-0000-0000";
       "REFERENCE", "https://www.doi.org/10.0000/synthetic"];
    Alcotest.(check string) "producer input bytes remain intact" before (read_text input))

let () = Alcotest.run "Public_forest"
  ["public-v2", [Alcotest.test_case "literal root and isolated Markdown" `Quick test_basic;
    Alcotest.test_case "exact schema rejects unknown keys and types" `Quick test_schema;
    Alcotest.test_case "strict IDs and case-fold uniqueness" `Quick test_ids;
    Alcotest.test_case "native nested sections and root ordering" `Quick test_nested;
    Alcotest.test_case "literal metadata and native inheritance" `Quick test_metadata;
    Alcotest.test_case "valid dates and safe native URLs" `Quick test_metadata_validation;
    Alcotest.test_case "structured transclusions and placement flags" `Quick test_transclusion;
    Alcotest.test_case "public targets and containment/transclusion cycles" `Quick test_graph;
    Alcotest.test_case "isolated Markdown allowlist refuses residual syntax" `Quick test_markdown_boundary;
    Alcotest.test_case "protected code examples and inert ordinary math" `Quick test_protected_examples;
    Alcotest.test_case "strict JSON grammar, UTF-8 and resource limits" `Quick test_json_grammar_and_bounds;
    Alcotest.test_case "JSON-only file API and Tree_of_md façade" `Quick test_file_api;
    Alcotest.test_case "official underscore CLI and required arguments" `Quick test_cli;
    Alcotest.test_case "fresh output namespace and symlink refusal" `Quick test_output_namespace;
    Alcotest.test_case "no writes or payload diagnostics on rejection" `Quick test_no_writes_on_rejection;
    Alcotest.test_case "inert encoded labels and protected text boundaries" `Quick test_literal_entity_labels;
    Alcotest.test_case "real Forester DOI/ORCID hrefs" `Quick test_native_identifier_links;
    Alcotest.test_case "strict native identifiers and official URL boundary" `Quick test_identifier_validation;
    Alcotest.test_case "v2 calendar dates only, legacy timestamps unchanged" `Quick test_calendar_dates_only]]
