open Tree_md

let with_dir f =
  let root = Filename.temp_file "tree-md-mint-" ".dir" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let rec remove path =
    try
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Sys.remove path
    with _ -> ()
  in
  Fun.protect ~finally:(fun () -> remove root) (fun () -> f root)

let write path contents =
  Out_channel.with_open_bin path (fun c -> Out_channel.output_string c contents)

let read path = In_channel.with_open_bin path In_channel.input_all

let relative value = Result.get_ok (Path_safe.relative value)

let config root =
  { Config.path = Filename.concat root "tree-md.toml";
    directory = root;
    forest =
      { Config.path = Filename.concat root "forest.toml";
        directory = root;
        tree_roots = [ (relative "generated", Filename.concat root "generated") ];
        asset_roots = [] };
    source_roots = [ (relative "trees-md", Filename.concat root "trees-md") ];
    output_root = (relative "generated", Filename.concat root "generated");
    target = Forester_6.target;
    id = Config.default_id_policy }

(* The default is random, which no assertion about particular addresses can
   pin down. Tests about where the counter starts and what it steps over ask
   for the sequential scheme by name. *)
let config_sequential root =
  let base = config root in
  { base with Config.id = { base.Config.id with Config.scheme = Config.Sequential } }

let source root name =
  { Discovery.source_root = Filename.concat root "trees-md";
    path = Filename.concat root ("trees-md/" ^ name ^ ".tree.md");
    config_relative = relative ("trees-md/" ^ name ^ ".tree.md");
    source_relative = relative (name ^ ".tree.md");
    output_relative = relative (name ^ ".tree");
    root_id = name }

let discovery root names =
  { Discovery.sources = List.map (source root) names; handwritten_roots = [] }

let plan_ok name result =
  match result with
  | Ok minted -> minted
  | Error diags ->
    Alcotest.fail (name ^ ": " ^ String.concat "; "
      (List.map (fun d -> d.Diagnostic.message) diags))

(* An address a person wrote is never taken away from them. *)
let test_states_id_is_left_alone () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    write (Filename.concat root "trees-md/named.tree.md") "---\nid: aboutme\n---\n# T\n";
    write (Filename.concat root "trees-md/bare.tree.md") "# T\n";
    let minted = plan_ok "plan" (Mint.plan (config root) ~taken:[] (discovery root ["named"; "bare"])) in
    Alcotest.(check (list string)) "only the unaddressed one"
      [ Filename.concat root "trees-md/bare.tree.md" ]
      (List.map (fun (m : Mint.minted) -> m.Mint.path) minted))

let test_addresses_avoid_what_is_taken () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    write (Filename.concat root "trees-md/a.tree.md") "# A\n";
    write (Filename.concat root "trees-md/b.tree.md") "# B\n";
    let minted =
      plan_ok "plan"
        (Mint.plan (config_sequential root) ~taken:[ "0000"; "0002" ]
           (discovery root ["a"; "b"]))
    in
    Alcotest.(check (list string)) "skips taken, and each other"
      [ "0001"; "0003" ] (List.map (fun (m : Mint.minted) -> m.Mint.id) minted))

(* Sequential starts at zero, as the plugin does; the two mint into one
   namespace and must not disagree about where it begins. *)
let test_sequential_starts_at_zero () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    write (Filename.concat root "trees-md/a.tree.md") "# A\n";
    let minted =
      plan_ok "plan" (Mint.plan (config_sequential root) ~taken:[] (discovery root ["a"]))
    in
    Alcotest.(check (list string)) "first address"
      [ "0000" ] (List.map (fun (m : Mint.minted) -> m.Mint.id) minted))

(* The default scheme is random. Nothing can be said about which addresses it
   picks, but everything can be said about their shape: policy-legal, distinct
   from each other, and clear of what the forest already answers to. *)
let test_random_is_the_default () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    let names = [ "a"; "b"; "c"; "d" ] in
    List.iter
      (fun n ->
        write (Filename.concat root ("trees-md/" ^ n ^ ".tree.md")) ("# " ^ n ^ "\n"))
      names;
    Alcotest.(check bool) "default is random" true
      (Config.default_id_policy.Config.scheme = Config.Random);
    let minted =
      plan_ok "plan" (Mint.plan (config root) ~taken:[ "ZZZZ" ] (discovery root names))
    in
    let ids = List.map (fun (m : Mint.minted) -> m.Mint.id) minted in
    Alcotest.(check int) "one each" (List.length names) (List.length ids);
    Alcotest.(check int) "all distinct" (List.length ids)
      (List.length (List.sort_uniq String.compare ids));
    List.iter
      (fun id ->
        Alcotest.(check int) ("width of " ^ id) 4 (String.length id);
        Alcotest.(check bool) ("digits of " ^ id) true
          (String.for_all
             (fun c -> String.contains Config.default_id_policy.Config.alphabet c)
             id);
        Alcotest.(check bool) ("clear of taken: " ^ id) true (id <> "ZZZZ"))
      ids)

(* The address goes in; every byte already in the note stays. *)
let test_apply_inserts_into_existing_frontmatter () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    let path = Filename.concat root "trees-md/a.tree.md" in
    write path "---\ntaxon: Note\n---\n\n# Title\n\nbody\n";
    (match Mint.apply [ { Mint.path; id = "0001" } ] with
     | Ok () -> ()
     | Error _ -> Alcotest.fail "apply failed");
    Alcotest.(check string) "id added, rest untouched"
      "---\nid: 0001\ntaxon: Note\n---\n\n# Title\n\nbody\n" (read path))

let test_apply_creates_frontmatter_when_absent () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    let path = Filename.concat root "trees-md/a.tree.md" in
    write path "# Title\n\nbody\n";
    (match Mint.apply [ { Mint.path; id = "0001" } ] with
     | Ok () -> ()
     | Error _ -> Alcotest.fail "apply failed");
    Alcotest.(check string) "front matter brought into being"
      "---\nid: 0001\n---\n\n# Title\n\nbody\n" (read path))

(* Applying is what makes the plan empty next time. *)
let test_minting_converges () =
  with_dir (fun root ->
    Unix.mkdir (Filename.concat root "trees-md") 0o700;
    write (Filename.concat root "trees-md/a.tree.md") "# A\n";
    let d = discovery root ["a"] in
    let first = plan_ok "first" (Mint.plan (config root) ~taken:[] d) in
    Alcotest.(check int) "one to mint" 1 (List.length first);
    (match Mint.apply first with Ok () -> () | Error _ -> Alcotest.fail "apply failed");
    let second = plan_ok "second" (Mint.plan (config root) ~taken:[] d) in
    Alcotest.(check int) "nothing left to mint" 0 (List.length second))

let () =
  let open Alcotest in
  run "Mint"
    [ "plan", [
        test_case "states_id_is_left_alone" `Quick test_states_id_is_left_alone;
        test_case "addresses_avoid_what_is_taken" `Quick test_addresses_avoid_what_is_taken;
        test_case "sequential_starts_at_zero" `Quick test_sequential_starts_at_zero;
        test_case "random_is_the_default" `Quick test_random_is_the_default;
      ]
    ; "apply", [
        test_case "inserts_into_existing_frontmatter" `Quick test_apply_inserts_into_existing_frontmatter;
        test_case "creates_frontmatter_when_absent" `Quick test_apply_creates_frontmatter_when_absent;
        test_case "minting_converges" `Quick test_minting_converges;
      ]
    ]
