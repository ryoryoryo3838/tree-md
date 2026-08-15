type expected = {
  source_path : string;
  source_config_relative : Path_safe.relative;
  output_relative : Path_safe.relative;
  bytes : string;
  sha256 : string;
}

val parse : root_id:string -> Source.t -> (Parsed_document.t, Diagnostic.t list) result

val emit :
  resolution:Resolution.t -> Parsed_document.t ->
  (string, Diagnostic.t list) result

val compile_forest :
  Config.t -> Discovery.t -> (expected list, Diagnostic.t list) result
