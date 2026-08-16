open Tree_md

let policy ?(alphabet = Config.default_id_policy.Config.alphabet)
    ?(width = 4) ?(prefix = "") () =
  { Config.alphabet; width; scheme = Config.Sequential; prefix; mint = Config.By_build }

(* Checked against addresses the Forester documentation actually publishes:
   its own trees 0052 and 007H are 182 and 269 in base 36. *)
let test_matches_forester_addresses () =
  let p = policy () in
  Alcotest.(check string) "0052" "0052" (Tree_id.encode p 182);
  Alcotest.(check string) "007H" "007H" (Tree_id.encode p 269);
  Alcotest.(check string) "0073" "0073" (Tree_id.encode p 255)

let test_pads_and_widens () =
  let p = policy () in
  Alcotest.(check string) "zero" "0000" (Tree_id.encode p 0);
  Alcotest.(check string) "one" "0001" (Tree_id.encode p 1);
  Alcotest.(check string) "last four-digit" "ZZZZ" (Tree_id.encode p (36 * 36 * 36 * 36 - 1));
  (* A number too large for the width takes another digit rather than wrapping. *)
  Alcotest.(check string) "widened" "10000" (Tree_id.encode p (36 * 36 * 36 * 36))

let test_prefix_and_alphabet () =
  Alcotest.(check string) "prefix" "mlnet-0001"
    (Tree_id.encode (policy ~prefix:"mlnet-" ()) 1);
  Alcotest.(check string) "decimal" "007"
    (Tree_id.encode (policy ~alphabet:"0123456789" ~width:3 ()) 7)

(* Whatever is minted has to be usable as an identity. *)
let test_result_is_a_valid_id () =
  let p = policy () in
  List.iter
    (fun n ->
      let id = Tree_id.encode p n in
      Alcotest.(check bool) ("valid: " ^ id) true (Metadata.valid_id id))
    [ 0; 1; 35; 36; 182; 1679615; 1679616 ]

let () =
  let open Alcotest in
  run "Tree_id"
    [ "encode", [
        test_case "matches_forester_addresses" `Quick test_matches_forester_addresses;
        test_case "pads_and_widens" `Quick test_pads_and_widens;
        test_case "prefix_and_alphabet" `Quick test_prefix_and_alphabet;
        test_case "result_is_a_valid_id" `Quick test_result_is_a_valid_id;
      ]
    ]
