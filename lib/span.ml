type t = {
  path : string;
  start_byte : int;
  end_byte : int;
}

type location = Source_span of t | Path of string | No_location

let make ~path ~start_byte ~end_byte =
  if start_byte < 0 then Error "start byte is negative"
  else if end_byte < start_byte then Error "end byte precedes start byte"
  else Ok { path; start_byte; end_byte }

let compare a b =
  let c = String.compare a.path b.path in
  if c <> 0 then c
  else
    let c = Int.compare a.start_byte b.start_byte in
    if c <> 0 then c
    else Int.compare a.end_byte b.end_byte
