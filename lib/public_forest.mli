(** Public-v2 JSON-only conversion. No source discovery or publication policy.
    Errors are stable codes and never contain input snippets or filenames. *)
type error = Invalid_json | Schema | Invalid_id | Duplicate_id | Invalid_date
           | Unsafe_markdown | Missing_target | Cycle | Limit | Io | Unsafe_output
type t
val error_code : error -> string
val of_string : string -> (t, error) result
val compile_forest : t -> ((string * string) list, error) result
val max_json_bytes : int
val max_json_depth : int
val max_tree_depth : int
val max_chunk_bytes : int
val load_file : string -> (t, error) result
(** Validate and compile everything before writing. Require a new or empty,
    nonsymlink output directory; never reuse stale output or overwrite files. *)
val write_forest : out_dir:string -> t -> (int, error) result
val convert_file : input:string -> out_dir:string -> (int, error) result
