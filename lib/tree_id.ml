(* Positional notation in the policy's alphabet. Zero-padding to a fixed width
   is what makes the addresses sort and read alike; a number too large for that
   width simply takes more digits rather than wrapping. *)
let encode (policy : Config.id_policy) n =
  let alphabet = policy.Config.alphabet in
  let base = String.length alphabet in
  let n = if n < 0 then 0 else n in
  let rec digits n acc = if n = 0 then acc else digits (n / base) (acc + 1) in
  let needed = max policy.Config.width (max 1 (digits n 0)) in
  let bytes = Bytes.make needed alphabet.[0] in
  let rec fill n i =
    if i < 0 || n = 0 then ()
    else begin
      Bytes.set bytes i alphabet.[n mod base];
      fill (n / base) (i - 1)
    end
  in
  fill n (needed - 1);
  policy.Config.prefix ^ Bytes.to_string bytes
