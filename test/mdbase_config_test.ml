open Tree_md

let with_directory f =
  let root = Filename.temp_file "tree-md-mdbase" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let root = Unix.realpath root in
  let rec remove path =
    try
      match (Unix.lstat path).Unix.st_kind with
      | Unix.S_DIR ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Sys.remove path
    with _ -> ()
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let write directory contents =
  let channel = open_out_bin (Filename.concat directory "mdbase.yaml") in
  output_string channel contents;
  close_out channel

let load directory = Mdbase_config.load ~directory

let expect_ok name directory =
  match load directory with
  | Ok result -> result
  | Error diagnostics ->
    Alcotest.fail
      (name ^ ": "
       ^ String.concat "; " (List.map (fun d -> d.Diagnostic.message) diagnostics))

let expect_error name directory =
  match load directory with
  | Ok _ -> Alcotest.fail (name ^ ": expected an error")
  | Error diagnostics -> diagnostics

let contains haystack needle =
  let n = String.length needle in
  let rec loop i =
    i + n <= String.length haystack
    && (String.sub haystack i n = needle || loop (i + 1))
  in
  loop 0

(* A forest with no mdbase.yaml is an ordinary forest: everything tree-md did
   before the file existed still works, on the defaults. *)
let test_absent_file_is_the_defaults () =
  with_directory (fun root ->
    let config, warnings = expect_ok "absent" root in
    Alcotest.(check int) "silent" 0 (List.length warnings);
    Alcotest.(check string) "default types folder" "_types"
      config.Mdbase_config.types_folder;
    Alcotest.(check string) "default id field" "id" config.Mdbase_config.id_field;
    Alcotest.(check bool) "validation defaults to error" true
      (config.Mdbase_config.validation = Mdbase_config.Strict))

let test_settings_are_read () =
  with_directory (fun root ->
    write root
      "spec_version: \"0.3.0\"\n\
       settings:\n\
      \  validation: warn\n\
      \  types_folder: types\n\
      \  id_field: uid\n\
      \  explicit_type_keys: [kind]\n";
    let config, warnings = expect_ok "settings" root in
    Alcotest.(check int) "silent" 0 (List.length warnings);
    Alcotest.(check bool) "validation" true
      (config.Mdbase_config.validation = Mdbase_config.Warn);
    Alcotest.(check string) "types folder" "types" config.Mdbase_config.types_folder;
    Alcotest.(check string) "id field" "uid" config.Mdbase_config.id_field;
    Alcotest.(check (list string)) "explicit type keys" [ "kind" ]
      config.Mdbase_config.explicit_type_keys)

(* §04 makes the minor component the compatibility boundary during major-zero,
   and requires a rejecting tool to report the exact identifier it supports. *)
let test_incompatible_spec_version () =
  with_directory (fun root ->
    write root "spec_version: \"0.2.1\"\n";
    let diagnostics = expect_error "0.2" root in
    Alcotest.(check bool) "names what is supported" true
      (List.exists
         (fun d -> contains d.Diagnostic.message Mdbase_config.supported_spec_version)
         diagnostics));
  with_directory (fun root ->
    write root "spec_version: \"0.3.7\"\n";
    ignore (expect_ok "same minor" root))

let test_missing_spec_version () =
  with_directory (fun root ->
    write root "settings:\n  validation: warn\n";
    ignore (expect_error "no spec_version" root))

(* §04: an unknown configuration key warns; loading continues. *)
let test_unknown_keys_warn () =
  with_directory (fun root ->
    write root "spec_version: \"0.3.0\"\nnonsense: 1\nsettings:\n  whatever: 2\n";
    let _config, warnings = expect_ok "unknown keys" root in
    Alcotest.(check int) "two warnings" 2 (List.length warnings);
    Alcotest.(check bool) "all warnings" false
      (Diagnostic.has_error warnings))

(* An `x-` key is the extension namespace, never a mistake. *)
let test_extension_keys_are_silent () =
  with_directory (fun root ->
    write root "spec_version: \"0.3.0\"\nx-local: 1\nsettings:\n  x-local: 2\n";
    let _config, warnings = expect_ok "extension keys" root in
    Alcotest.(check int) "silent" 0 (List.length warnings))

(* A setting that decides nothing here says so, rather than being accepted and
   quietly having no effect. *)
let test_inert_settings_warn () =
  with_directory (fun root ->
    write root "spec_version: \"0.3.0\"\nsettings:\n  record_extensions: [md]\n";
    let _config, warnings = expect_ok "inert" root in
    Alcotest.(check int) "one warning" 1 (List.length warnings);
    Alcotest.(check bool) "explains" true
      (contains (List.hd warnings).Diagnostic.message "no effect"))

let test_invalid_validation_level () =
  with_directory (fun root ->
    write root "spec_version: \"0.3.0\"\nsettings:\n  validation: strict\n";
    ignore (expect_error "bad level" root))

let () =
  let open Alcotest in
  run "Mdbase_config"
    [ "load", [
        test_case "absent_file_is_the_defaults" `Quick test_absent_file_is_the_defaults;
        test_case "settings_are_read" `Quick test_settings_are_read;
        test_case "incompatible_spec_version" `Quick test_incompatible_spec_version;
        test_case "missing_spec_version" `Quick test_missing_spec_version;
        test_case "unknown_keys_warn" `Quick test_unknown_keys_warn;
        test_case "extension_keys_are_silent" `Quick test_extension_keys_are_silent;
        test_case "inert_settings_warn" `Quick test_inert_settings_warn;
        test_case "invalid_validation_level" `Quick test_invalid_validation_level;
      ]
    ]
