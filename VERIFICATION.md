# tree-md Verification Matrix

This file maps every design requirement of the tree-md compiler to an exact
test executable, cram scenario, or compatibility-fixture assertion. It is the
acceptance record for the implementation.

Test executables are the Alcotest binaries under [`test/`](./test); cram
scenarios live in [`test/cli.t/run.t`](./test/cli.t/run.t); the external
compatibility job is [`test/forester_compat.sh`](./test/forester_compat.sh)
plus the `test/fixtures/compat` fixture.

## Full-suite status

- 24 Alcotest suites, **567 tests, all passing** (`dune runtest`).
- Cram scenario `cli.t` runs under `dune runtest` and passes.
- All 27 stable diagnostic codes (`TM001`–`TM500`) are exercised by at least
  one test (verified by code search; see the Diagnostics section).
- The checked-in golden fixture `test/fixtures/markdown/complete.tree.md` and
  its expected `test/fixtures/forester/complete.tree` were regenerated in the
  final-fix commit to drop the stray `\verbFMD|[FMD`/`\verbFMD|]FMD` bracket
  escapes that the inline-wiki overlap fix removes (see the whole-branch
  review findings 1–2).
- Existing handwritten tree hashes are unchanged after the fresh verification
  (see Acceptance Criteria below).

## Spec section → test mapping

### Compatibility Target (lines 65–112)

| Requirement | Test |
| --- | --- |
| Profile identifies `forester-6.0-dev@30b73641cef02433ee158db6ddc77f7b49de60be` | `config_test.ml` (`target`, `unsupported_target`); `workspace_test.ml` (`config_error_tm401`) |
| `\title`/`\date`/`\taxon`/`\author`/`\author/literal`/`\contributor`/`\contributor/literal`/`\tag`/`\meta` forms | `forester_6_test.ml` (`metadata_date`, `metadata_taxon`, `metadata_authors_tree`, `metadata_authors_literal`, `metadata_contributors`, `metadata_tags`, `metadata_meta`, `metadata_order`) |
| `\p`/`\em`/`\strong`/`\code`/`\blockquote`/`\ul`/`\ol`/`\pre` forms | `forester_6_test.ml` (`emission_blocks`, `emission_lists`, `code_block_*`, `blockquote`, `simple_paragraph`) |
| `[[target]]`, `[Label](target)`, `\transclude{target}`, `#{...}`, `##{...}` | `forester_6_test.ml` (`wiki_link_emission`, `wiki_link_alias_emission`, `wiki_embed_emission`, `transclusion_no_extra_wrapper`, `inline_math_emission`, `display_math_inline_emission`, `display_math_block_emission`) |
| `\subtree[stable-id]` / `\subtree` sections | `forester_6_test.ml` (`named_and_anon_sections`, `emission_sections`) |
| External compatibility against pinned commit | `test/forester_compat.sh` + `test/fixtures/compat` (CI job, version-gated; see Compatibility Job) |

### Configuration (lines 171–196)

`mdbase.yaml` is covered under mdbase conformance above; the table below is
`tree-md.toml`.

| Requirement | Test |
| --- | --- |
| `version`/`forest`/`sources`/`output`/`target` schema, required fields | `config_test.ml` (`missing_field`, `unknown_field`, `wrong_version`, `unsupported_target`) |
| `--config PATH`; default exactly `./tree-md.toml`, no parent search | `cli.t/run.t` (default-config scenario, `TM401` when ancestor config is absent) |
| Paths relative to `tree-md.toml` directory; `forest.toml` paths relative to `forest.toml` | `config_test.ml` (`valid_path_bases`, `valid_nested_forest_path_bases`, `relative_operations`) |
| Distinct source roots; output not overlapping a source root | `config_test.ml` (`duplicate_source_root`, `source_output_overlap`) |
| Absolute/empty/`.`/`..` path rejection; output in `[forest].trees` | `config_test.ml` (`absolute_path`, `empty_segment`, `dot_segment`, `dot_dot_segment`, `backslash_path`, `output_absent_from_forest_trees`) |
| `[id]` policy: defaults follow Forester's convention, overrides load, unusable alphabets/prefixes rejected | `config_test.ml` (`id_defaults`, `id_overrides`, `id_rejects_unusable_policy`) |
| `build` mints into sources, reports what it gave, and converges; `check` stays read-only | `workspace_test.ml` (lifecycle suites, whose fixtures now state ids); `mint_test.ml` |
| A stated `id` is never minted over; addresses avoid what is taken; front matter is created when absent and otherwise byte-preserved; minting converges | `mint_test.ml` (`states_id_is_left_alone`, `addresses_avoid_what_is_taken`, `inserts_into_existing_frontmatter`, `creates_frontmatter_when_absent`, `minting_converges`) |
| `scheme` defaults to `random`; `sequential` starts at zero, matching the plugin that mints into the same namespace | `mint_test.ml` (`random_is_the_default`, `sequential_starts_at_zero`); `config_test.ml` (`id_defaults`) |
| Minted addresses match the published Forester convention and are legal identities | `tree_id_test.ml` (`matches_forester_addresses`, `pads_and_widens`, `prefix_and_alphabet`, `result_is_a_valid_id`) |
| Unsupported `target` is a configuration error | `cli.t/run.t` (`TM401` unsupported-target scenario, exit 2) |

### Source Discovery and Identity (lines 198–221)

| Requirement | Test |
| --- | --- |
| Recursive scan, no symlink following, dot-leading components ignored | `discovery_test.ml` (`symlinks_skipped`, `hidden_source_root_skipped`, `symlinked_source_root`) |
| Files end exactly in `.tree.md`; mirror to output | `discovery_test.ml` (`discovers_and_mirrors`); `forest_compile_test.ml` |
| A file name is a search key, so any stem is discovered | `discovery_test.ml` (`nonaddress_source_stems_accepted`, `duplicate_stems_accepted`) |
| A handwritten `.tree` stem must still be an address, since Forester reads it as one | `discovery_test.ml` (`invalid_handwritten_stem`, `duplicate_handwritten_stems`) |
| Root identity is the stated `id`, else the stem when it could be an address and is unshared | `forest_compile_test.ml` (`unaddressed_tree_tm206`, `unaddressed_tree_allowed_before_minting`); `forest_index_test.ml` (`duplicate_generated_roots`, `generated_versus_handwritten_root`) |
| Address grammar `[A-Za-z0-9][A-Za-z0-9._-]*` | `frontmatter_test.ml` (`valid_id`, `parse_attribution_bad_id`) |
| Target grammar: any file name minus `[ ] \| # ^ \\` | `wiki_test.ml` (`spaced_target_accepted`, `japanese_target_accepted`, `backslash_target_diagnostic`); `inline_test.ml` (`parse_wiki_bad_id`, `parse_wiki_japanese_target`) |
| A title with no H1 falls back to the file name, not the identity | `outline_test.ml` (`title_falls_back_to_filename`) |

### YAML Front Matter (lines 228–277)

| Requirement | Test |
| --- | --- |
| Front matter ends at the FIRST closing fence; a later `---` is body | `frontmatter_test.ml` (`first_fence_closes_frontmatter`, `missing_closing_delim`, `no_frontmatter`) |
| One top-level mapping; scalar string keys; no duplicate keys/anchors/aliases/tags/multiple documents | `frontmatter_test.ml` (`duplicate_keys`, `yaml_alias`, `non_scalar_key_rejected`) |
| An uninterpreted key is carried, not rejected; a near miss warns; `x-` never warns | `frontmatter_test.ml` (`unknown_keys`, `misspelled_meta_key`, `extension_key_never_warns`) |
| A shape cannot mislead the reader: a promoted key given a list | `frontmatter_test.ml` (`promoted_key_with_list_value`) |
| A bare scalar stands for a one-element list, as Obsidian writes it | `frontmatter_test.ml` (`scalar_tags_accepted`) |
| A value read as text keeps the bytes it was written as | `frontmatter_test.ml` (`scalar_text_is_preserved`) |
| Date formats accepted/rejected (RFC 3339 subset) | `frontmatter_test.ml` (`valid_date_format`, `valid_date_invalid`) |
| `taxon`, `authors`/`contributors` (`[[id]]` vs literal), `tags`, `meta` schema | `frontmatter_test.ml` (`valid_frontmatter`, `parse_attribution_tree`, `parse_attribution_literal`, `parse_attribution_bad_id`); `forest_index_test.ml` (`unresolved_attributions`) |
| Meta names promoted to top-level keys; one name set once | `frontmatter_test.ml` (`promoted_meta_keys`, `promoted_meta_mixed`, `duplicate_meta_key`) |
| Metadata values parsed as inline Markdown | `inline_test.ml` (`metadata_lower_meta`, `metadata_lower_tags`) |
| YAML scalar span locations after escape decoding | `frontmatter_test.ml` (`tag_real_spans`); `inline_test.ml` (`metadata_lower_*`) |
| Canonical metadata emission order independent of key order | `forester_6_test.ml` (`metadata_order`) |
| `TM002` on YAML syntax/delimiter failure | `frontmatter_test.ml`; `cli_test.ml` |

### Root Title, Sections, Subtrees (lines 279–327)

| Requirement | Test |
| --- | --- |
| H1 first block → root `\title`, no body node; filename-stem fallback | `outline_test.ml` (`root_title`, `fallback_span`); `compiler_test.ml` (`golden_complete`) |
| ATX and setext headings | `block_test.ml` (`atx_heading`, `setext_heading`) |
| H1 anywhere else is an error | `block_test.ml`; `outline_test.ml`; `TM103` in `cli_test.ml` |
| H2–H6 nesting; skipped level error; closing semantics | `outline_test.ml` (`hierarchy`, `same_level_closes`, `shallower_closes_deeper`, `skipped`); `TM103` |
| Headings nested in lists/blockquotes are errors | `block_test.ml` (`nested_heading_rejected`) |
| Anonymous vs named (`<!-- subtree: ID -->`) sections; directive grammar | `outline_test.ml` (`named`, `multiple_definitions`, `definition_span_points_to_directive`); `block_test.ml` (`subtree_directive`); `TM104` |
| Orphan directive, directive before H1, invalid ID, global collision | `outline_test.ml` (`orphan`, `orphan_directive_in_section`, `directive_at_end`, `directive_then_para`, `errors`); `block_test.ml` (`subtree_directive_invalid_id`); `compiler_test.ml` (`subtree_directive_invalid_id`); `TM104`; `forest_index_test.ml` (`root_versus_named_subtree`) |

### Obsidian Links and Embeds (lines 330–368)

| Requirement | Test |
| --- | --- |
| `[[id]]` → `[[id]]`; `[[id\|alias]]` → `[alias](id)` | `wiki_test.ml` (`simple_wiki_link`, `wiki_link_with_alias`, `wiki_embed`); `forester_6_test.ml` (`wiki_link_emission`, `wiki_link_alias_emission`) |
| `![[id]]` standalone → `\transclude{id}`, no wrapper | `block_test.ml` (`embed_normalization`); `forester_6_test.ml` (`wiki_embed_emission`, `transclusion_no_extra_wrapper`) |
| Embed placement errors (lists, blockquotes, ordinary paragraphs) | `block_test.ml` (`embed_in_list_rejected`, `embed_in_blockquote_rejected`, `embed_in_blockquote_list_rejected`, `inline_embed_rejected`, `text_and_embed_rejected`); `TM106` |
| Invalid targets/aliases → `TM105` | `wiki_test.ml` (`backslash_target_diagnostic`, `empty_alias_diagnostic`, `multiple_pipes_diagnostic`); `inline_test.ml` (`parse_wiki_empty_alias`, `parse_wiki_multi_pipe`) |
| A target may be spelled as a file name — spaces, any script | `wiki_test.ml` (`spaced_target_accepted`, `japanese_target_accepted`); `inline_test.ml` (`parse_wiki_bad_id`, `parse_wiki_japanese_target`); `forest_index_test.ml` (`nonascii_filename_resolves`) |
| `.tree` and `.md` suffixes strip cumulatively; exact spelling wins | `forest_index_test.ml` (`tree_suffix_resolves`, `tree_suffix_exact_match_wins`, `md_suffix_resolves`) |
| `[[folder/note]]` resolves path-style | `forest_index_test.ml` (`path_style_target_resolves`) |
| A name reaching several files is settled by mdbase v0.3 §08 order | `forest_index_test.ml` (`ambiguous_filename_prefers_own_folder`); `cli.t/run.t` (the ambiguity warning) |
| Unclosed Wiki stays literal; code/escaped text protected | `wiki_test.ml` (`unclosed_is_literal`, `code_span_not_wiki`, `escaped_not_wiki`, `double_backslash_is_wiki`, `three_backslashes_not_wiki`, `larger_bracket_run`, `right_bracket_run`, `left_bracket_run`) |
| `[alias][[id]]` reference resolution (with/without definition); escaped with definition | `wiki_test.ml` (`reference_link_not_wiki`, `reference_with_definition`, `escaped_with_definition`) |
| Cmarkit characterization gate (parser contract) | `wiki_test.ml` (entire suite — resolver idempotence `repeated_calls`, `second_call_same`); `source_test.ml` |

### Math (lines 369–378)

| Requirement | Test |
| --- | --- |
| `$...$` → `#{...}`; standalone `$$...$$` → `##{...}` | `inline_test.ml` (`inline_math`, `display_math`); `forester_6_test.ml` (`inline_math_emission`, `display_math_inline_emission`, `display_math_block_emission`) |
| Display math placement errors | `block_test.ml` (`display_math_in_list_rejected`, `display_math_in_blockquote_rejected`, `display_math_in_blockquote_list_rejected`, `text_and_display_math_rejected`, `inline_display_math_rejected`); `TM107` |
| Unclosed `$` stays literal; empty/structurally invalid math rejected | `inline_test.ml` (`parse_unbalanced_math`, `parse_empty_math`); `forester_6_test.ml` (`math_unbalanced_error`, `math_balanced_passes`) |
| Math payload serialized via target-profile scanner | `forester_6_test.ml` (`math_balanced_passes`, `math_unbalanced_error`); `TM107` |

### Supported Markdown Mapping (lines 380–447)

| Requirement | Test |
| --- | --- |
| Paragraph / emphasis / strong / inline code | `forester_6_test.ml` (`simple_paragraph`, `emphasis_emission`, `strong_emission`, `inline_code_emission`); `inline_test.ml` |
| Block quote (nested) | `block_test.ml` (`blockquote`, `blockquote_deep_structure`, `nested_blockquote`) |
| Unordered/ordered lists, start preservation, tight/loose `\p` | `block_test.ml` (`tight_list`, `loose_list`, `list_ordered_start_preserved`, `list_tightness_preserved`, `nested_list`); `forester_6_test.ml` (`tight_unordered_list`, `loose_unordered_list`) |
| H2–H6 → nested `\subtree` | `forester_6_test.ml` (`emission_sections`, `named_and_anon_sections`) |
| Wiki links / labelled links / transclusion | `forester_6_test.ml` (emission tests above) |
| Math | `forester_6_test.ml` (emission tests above) |
| Ordinary links, autolinks (normalized), images (external + local `\route-asset`), titles | `forester_6_test.ml` (`external_link_emission`, `http_link_emission`, `external_link_with_title`, `external_image_emission`, `http_image_emission`, `local_image_with_resolution`, `local_image_no_resolution_error`, `image_alt_flattening`); `inline_test.ml` (`autolink`, `autolink_email`, `image`, `image_with_title`) |
| Thematic break, hard/soft line breaks | `forester_6_test.ml` (`thematic_break_emission`, `hard_break_emission`, `soft_break_emission`) |
| Indented + fenced code (info string rules, `language-TOKEN` class, `math` reserved) | `block_test.ml` (`indented_code`, `indented_code_multi_line`, `fenced_code_no_lang`, `fenced_code_ocaml`, `fenced_code_multi_line`, `invalid_lang_token_rejected`, `multi_token_fence_rejected`, `fenced_math_rejected`, `code_block_protects_wiki`, `code_block_protects_math`); `forester_6_test.ml` (`code_block_no_lang`, `code_block_with_lang`, `code_block_multiline`, `hostile_code_block_content`) |
| HTML comments discarded | `block_test.ml` (`comment_discarded`); `compiler_test.ml` (`html_comment_inline_discarded`, `html_comment_block_discarded`) |
| Reference-style links resolved before lowering | `wiki_test.ml` (`reference_with_definition`); `inline_test.ml` |
| **Golden assertion covering every mapping** | `compiler_test.ml` (`golden_complete`: `fixtures/markdown/complete.tree.md` → `fixtures/forester/complete.tree`, byte-identical) + `roundtrip_deterministic` |

### mdbase v0.3.0 conformance

| Requirement | Test |
| --- | --- |
| A forest with no `mdbase.yaml` and no `_types/` is unchanged | `mdbase_config_test.ml` (`absent_file_is_the_defaults`); `mdbase_type_test.ml` (`absent_folder_is_no_types`) |
| §04 settings are read and acted on | `mdbase_config_test.ml` (`settings_are_read`) |
| §04 spec-version compatibility boundary is the minor component | `mdbase_config_test.ml` (`incompatible_spec_version`, `missing_spec_version`) |
| §04 unknown config keys warn; `x-` never does; inert settings say so | `mdbase_config_test.ml` (`unknown_keys_warn`, `extension_keys_are_silent`, `inert_settings_warn`) |
| §03 front matter is an arbitrary mapping in the JSON data model | `yaml_json_test.ml` (`scalar_resolution`, `quoted_is_string`, `text_is_preserved`) |
| §06 non-JSON YAML values are rejected with a clear diagnostic | `yaml_json_test.ml` (`non_json_scalars_rejected`) |
| §06 required keyword profile, and refusal of anything outside it | `json_schema_test.ml` (`profile` and `assertions` groups) |
| §06 `format: date` / `date-time` / `time` assert RFC 3339 | `json_schema_test.ml` (`formats`) |
| §07 regular-expression subset: no backreferences, no look-around | `json_schema_test.ml` (`unsupported_regex_refused`) |
| §05 type files load; names conflict case-insensitively | `mdbase_type_test.ml` (`minimal_type_loads`, `duplicate_names_conflict`) |
| §02 a non-type file under the types folder warns and is never a record | `mdbase_type_test.ml` (`non_type_file_warns`) |
| A section tree-md does not act on is refused, not ignored | `mdbase_type_test.ml` (`unsupported_sections_refused`, `unsupported_collection_members_refused`, `match_expr_refused`) |
| §07 selection: explicit declaration completes it; inferred rules otherwise | `mdbase_type_test.ml` (`explicit_declaration_wins`, `path_glob_selects`, `fields_present_and_where`) |
| §07 `read_defaults` fill only missing keys; explicit null stays null | `yaml_json_test.ml` (`defaults_fill_only_missing`); `mdbase_type_test.ml` (`read_defaults`); `cli.t/run.t` |
| Schema issues are reported at `settings.validation`'s severity, with a span and mdbase's code | `cli.t/run.t` (the mdbase scenario) |
| RFC 6901 pointers locate the failing bytes | `yaml_json_test.ml` (`locate_points_at_the_value`, `locate_escapes`, `locate_missing_falls_back`) |

### Markdown that HTML has an element for

| Requirement | Test |
| --- | --- |
| `~~strikethrough~~` → `\<html:del>` | `inline_test.ml` (`strikethrough_lowered`); golden fixture |
| `==highlight==` → `\<html:mark>`; never inside a code span | `inline_test.ml` (`highlight_lowered`, `highlight_ignored_in_code`); golden fixture |
| `%%comment%%` discarded | `inline_test.ml` (`obsidian_comment_dropped`); golden fixture |
| GFM table → `\<html:table>`, ragged rows padded, alignment as a cell style | `block_test.ml` (`gfm_table_lowered`); golden fixture |
| Task items → a disabled checkbox | `block_test.ml` (`task_marker_lowered`); golden fixture |
| Obsidian callout → Obsidian's own blockquote markup | golden fixture (`complete.tree.md` / `complete.tree`) |
| Footnotes numbered by reference order; gathered at the end; unreferenced dropped | `block_test.ml` (`footnotes_numbered_by_reference`, `unreferenced_footnote_dropped`); golden fixture |
| `![[x.png]]` embeds an attachment, found by name under the asset roots | `forest_index_test.ml` (assets); golden fixture |
| A local Markdown link resolves as a tree reference; an external URL does not | `forest_index_test.ml` (`markdown_link_resolves`, `markdown_link_unresolved_errors`, `external_link_not_resolved`) |
| Percent-encoding is idempotent and applied only on the way out | `inline_test.ml` (`parse_link_space_encoded`) |

### Rejected Markdown (lines 440–447)

| Requirement | Test |
| --- | --- |
| Raw inline and block HTML rejected | `inline_test.ml` (`raw_html_rejected`); `block_test.ml` (`raw_html_block_rejected`); `cli.t/run.t` (`TM102` raw block HTML) |
| GFM tables / task markers / strikethrough / footnotes rejected | `block_test.ml` (`gfm_table_rejected`, `task_marker_rejected`, `footnote_rejected`); `inline_test.ml` (`strikethrough_rejected`) |
| Fenced math blocks rejected | `block_test.ml` (`fenced_math_rejected`) |
| Every unrecognized Cmarkit extension node rejected | `TM102` exercised in `block_test.ml`, `inline_test.ml`, `forest_compile_test.ml`, `cli.t/run.t` |
| No raw Forester pass-through | every rejected class above has a diagnostic assertion; `TM102` |

### Forester Serialization (lines 450–486)

| Requirement | Test |
| --- | --- |
| Canonical metadata order (title, date, taxon, authors, contributors, tags, meta, body) | `forester_6_test.ml` (`metadata_order`, `emission_metadata`) |
| UTF-8, LF endings, one final newline | `forester_6_test.ml` (`lf_normalization`, `final_newline`) |
| Text escaping: `%`→`\%`; `\ # { } [ ] ( )` → `\verbFMD|CHARFMD` | `forester_6_test.ml` (`escape_percent`, `escape_backslash`, `escape_hash`, `escape_lbrace`, `escape_rbrace`, `escape_lbracket`, `escape_rbracket`, `escape_lparen`, `escape_rparen`, `escape_mixed`, `escape_full_string`, `escape_unchanged`, `hostile_chars_in_paragraph`, `hostile_inline_code`, `deeply_nested_inlines`) |
| URI / XML-attribute writers normalize then escape | `inline_test.ml` (`uri_percent_encode_space`, `uri_fragment_encoded`, `uri_link_relative_encoded`, `parse_link_space_encoded`); `forester_6_test.ml` (`xml_attr_escaping`) |
| `<`, `>`, `&` preserved as text nodes | `forester_6_test.ml` (`hostile_chars_in_paragraph`) |
| Math payload scanner rejects unserializable TeX | `forester_6_test.ml` (`math_unbalanced_error`); `TM107` |

### Forest-wide Validation (lines 488–509)

| Requirement | Test |
| --- | --- |
| Index of generated roots + explicit subtree IDs + handwritten roots | `forest_index_test.ml` (`forest_wide`, `duplicate_generated_roots`, `duplicate_subtree_orders_by_byte`) |
| Collisions reported with both definition locations | `forest_index_test.ml` (`root_versus_named_subtree`, `generated_versus_handwritten_root`); `TM201` |
| Wiki/embed closed-world resolution; attributions resolve | `forest_index_test.ml` (`unresolved_wiki_link`, `unresolved_embed`, `unresolved_attributions`, `forest_wide_resolution_ok`, `literal_and_plain_link_ignored`); `TM202` |
| Front-matter `id` is the identity and names the output; the file name is the fallback | `frontmatter_test.ml` (`id_key`, `invalid_id_rejected`) |
| A reference may name the file; identities are tried first | `forest_index_test.ml` (`filename_resolves_to_id`, `identity_beats_filename`) |
| `.tree`-suffixed targets fall back to the stem; exact match wins; emission uses the identity | `forest_index_test.ml` (`tree_suffix_resolves`, `tree_suffix_exact_match_wins`, `tree_suffix_unresolved_errors`); `forester_6_test.ml` (`resolved_reference_uses_identity`) |
| `note#^id` resolves to the subtree `id`; `#^id` alone names the current note's; `#Heading` is `TM105` | `block_test.ml` (`embed_subtree_anchor`, `link_subtree_anchor`, `same_note_anchor`, `heading_fragment_rejected`) |
| An anchor ending a heading names the subtree it opens; naming it twice is `TM104` | `block_test.ml` (`heading_anchor_names_subtree`, `heading_anchor_and_directive_conflict`) |
| `id` names a subtree as `subtree` does; an empty one is `TM104` | `block_test.ml` (`id_directive`, `id_directive_needs_identifier`) |
| Trailing `^id` block anchors are stripped, not emitted; `x^2` is untouched; an anchor-only paragraph is dropped | `block_test.ml` (`block_anchor_stripped`, `caret_in_text_kept`, `standalone_anchor_dropped`) |
| Ordinary links exempt from closed-world rule | `forest_index_test.ml` (`single_match_routes`) |
| Multi-location diagnostics | `forest_index_test.ml` (`duplicate_subtree_orders_by_byte`); `diagnostic_test.ml` (`sort_by_path_then_byte`, `path_location_sorts_after_span`, `no_location_sorts_last`) |

### URL and Path Safety (lines 511–522)

| Requirement | Test |
| --- | --- |
| Scheme allowlist (`http`, `https`, `mailto`, fragments, safe relative); `javascript`/`data` rejected | `inline_test.ml` (`uri_mailto_accepted`, `uri_fragment_accepted`, `uri_relative_accepted`, `uri_javascript_rejected`, `uri_data_image_rejected`, `parse_link_javascript_rejected`, `parse_image_data_rejected`, `uri_nul_rejected`); `TM205` |
| External images only `http`/`https`; local assets resolve to exactly one asset root | `forest_index_test.ml` (`assets`, `single_match_routes`); `cli.t/run.t` (`TM203`, `TM204`); `TM205` |
| An asset is looked up as written, not percent-encoded, so a non-ASCII or spaced name resolves | `forest_index_test.ml` (`nonascii_asset_resolves`, `spaced_asset_resolves`); `inline_test.ml` (`uri_percent_encode_space` asserts both spellings) |
| Asset traversal rejection (`/`, `\`, NUL, empty, `.`, `..` segments) | `config_test.ml` (`relative_rejects_unsafe_paths`, `absolute_path`, `empty_segment`, `dot_segment`, `dot_dot_segment`, `backslash_path`) |
| Output paths confined under the output root | `manifest_test.ml` (path checks); `workspace_fs_test.ml` (`symlink_refusal`) |

### Manifest and Generated-file Ownership (lines 524–666)

| Requirement | Test |
| --- | --- |
| Manifest schema (format 1, compiler 0.1.0, target, files, sorted entries, 64-hex SHA-256) | `manifest_test.ml` (`canonical_schema`, `canonical_empty`, `canonical_sorted_entries`, `round_trip`, `decode_sorts`); `TM402` |
| Malformed JSON / unknown fields / wrong types / duplicate / bad hash / non-normalized paths rejected | `manifest_test.ml` (`malformed_json`, `unknown_field`, `entry_unknown_field`, `duplicate_field`, `duplicate_source`, `duplicate_output`, `short_hash`, `uppercase_hash`, `hash_wrong_type`, `non_tree_md_source`, `non_tree_output`, `absolute_path`, `dot_and_dotdot_path`, `tree_md_component`); `TM402` |
| Output-root reserved names (`manifest`, `transaction`, `lock`, `stage`) | `manifest_test.ml` (`tree_md_component`) |
| Only `build` takes the exclusive lock; validation before lock | `workspace_fs_test.ml` (`lock`, `contention`, `cross_process`); `workspace_test.ml` (`build_concurrency`) |
| `check` never creates/locks; read-only lock test; active writer → exit 2; state-digest double check | `workspace_test.ml` (`check_concurrency`, `active_writer_tm404`, `first_check_missing_no_writes`); `cli_test.ml` |
| Unknown files never deleted; unknown file at expected output → failure | `workspace_test.ml` (`unknown_collision_rejected`); `TM304` |
| Manual-modification protection (hash match required; no `--force`) | `workspace_test.ml` (`manually_modified_protection`); `cli.t/run.t` (`TM302` tampered-output scenario) |
| Transaction journal schema, null conventions, sorted operations | `transaction_test.ml` (`canonical_*`, `first_build_canonical`, `mixed_canonical`, `sort_invariant`, `inconsistent_null_combinations`, `operation_*`, `temporary_outside_stage`); `TM403` |
| Committed-journal cleanup (verify new hashes, remove temps, remove journal) | `transaction_test.ml` (`committed_cleanup`, `committed_cleanup_leftover_temps`, `committed_first_build`); `workspace_fs_test.ml` (`after_manifest`) |
| Roll-forward: create/replace/delete state verification, temp verification, manifest-last, journal-removed-last | `transaction_test.ml` (`roll_forward`, `replace_new_delete_absent`, `first_build`, `first_build_partial`, `output_states`, `temporary_states`, `current_manifest`, `all_validation_before_actions`); `workspace_test.ml` (`interrupted_journal_roll_forward`) |
| Recovery-before-parse; subsequent source error leaves prior transaction's completed state | `workspace_test.ml` (`interrupted_journal_roll_forward`, `source_error_leaves_output_unchanged`) |
| Malformed journal / base-manifest mismatch → exit 2, no deletion | `transaction_test.ml` (`malformed_json`, `base_hash` mismatch, `invalid_id`, `manifest_temporary_txn_mismatch`); `TM403` |
| Orphan stage: `check` reports TM306; `build` removes only validated non-symlink content | `workspace_test.ml` (`orphan_stage_removed`); `workspace_fs_test.ml` (`orphan_stage`, `cleanup`, `in_stage`, `in_cleanup`); `TM306` |
| Final parent creation derived from journaled paths, no symlink traversal | `workspace_fs_test.ml` (`deep_nesting`, `symlink_refusal` (`ancestor`, `output_root`, `output_file`)) |
| Durability-barrier ordering (flush journal, parents, manifest, dirs) | `workspace_fs_test.ml` (`durability` (`barriers`, `deep_nesting`)); fault-injection order `after_stage`, `after_journal_stage`, `after_output`, `after_manifest` |

### CLI Semantics and Exit Codes (lines 668–705)

| Requirement | Test |
| --- | --- |
| `build` validate-first, stage, journal, rename, manifest-last, cleanup | `workspace_test.ml` (`build_lifecycle` 0–12) |
| `check` same pipeline without writing; missing/modified/stale/colliding outputs as errors | `workspace_test.ml` (`check_lifecycle` 0–10); `cli.t/run.t` (`TM301`, `TM302` scenarios) |
| Exit 0 / 1 / 2 semantics, worst-wins | `cli_test.ml` (`exit codes` 0–11: success, source, semantic, state, config, manifest, journal, io, internal, worst wins, all class one, all class two) |
| Usage errors (missing/unknown command, unknown option) exit 2 | `cli.t/run.t` (three usage scenarios); `aae8d20` pinned behavior |
| Backtrace hidden by default, shown with `TREE_MD_BACKTRACE=1`, `Out_of_memory`/`Sys.Break` re-raised | `cli_test.ml` (`exception filter` 0–3) |
| `build`/`check` stdout/stderr contract | `cli.t/run.t` (summary line, silent clean check, stderr diagnostics) |
| `--version` prints the package version; `--help` documents the commands and exit codes, asserted as `--help=plain` so the recorded output does not depend on whether groff and a pager are present | `cli.t/run.t` (`--version`, `--help=plain`) |

### Diagnostics (lines 707–764)

All 27 stable codes are exercised:

| Code | Asserted in |
| --- | --- |
| `TM001` | `diagnostic_test.ml`, `cli_test.ml` |
| `TM002` | `frontmatter_test.ml`, `cli_test.ml` |
| `TM003` | `cli_test.ml` |
| `TM101` | `frontmatter_test.ml`, `cli_test.ml` |
| `TM102` | `block_test.ml`, `inline_test.ml`, `forest_compile_test.ml`, `cli.t/run.t` |
| `TM103` | `outline_test.ml`, `block_test.ml`, `diagnostic_test.ml`, `cli_test.ml` |
| `TM104` | `outline_test.ml`, `block_test.ml`, `compiler_test.ml`, `cli_test.ml` |
| `TM105` | `wiki_test.ml`, `inline_test.ml`, `cli_test.ml` |
| `TM106` | `block_test.ml`, `forester_6_test.ml`, `cli_test.ml` |
| `TM107` | `block_test.ml`, `inline_test.ml`, `forester_6_test.ml`, `cli_test.ml` |
| `TM201` | `forest_index_test.ml`, `discovery_test.ml`, `cli_test.ml` |
| `TM202` | `forest_index_test.ml`, `forest_compile_test.ml`, `workspace_test.ml`, `cli.t/run.t` |
| `TM203` | `forest_index_test.ml`, `forest_compile_test.ml`, `cli.t/run.t` |
| `TM204` | `forest_index_test.ml`, `forest_compile_test.ml`, `cli.t/run.t` |
| `TM205` | `inline_test.ml`, `discovery_test.ml`, `forest_index_test.ml`, `cli_test.ml` |
| `TM206` | `forest_compile_test.ml` (`unaddressed_tree_tm206`) |
| `TM301` | `workspace_test.ml`, `cli.t/run.t` |
| `TM302` | `workspace_test.ml`, `cli.t/run.t` |
| `TM303` | `workspace_test.ml`, `cli_test.ml` |
| `TM304` | `workspace_test.ml`, `cli_test.ml` |
| `TM305` | `workspace_test.ml`, `cli_test.ml` |
| `TM306` | `workspace_test.ml`, `cli_test.ml` |
| `TM401` | `config_test.ml`, `workspace_test.ml`, `cli.t/run.t` |
| `TM402` | `manifest_test.ml`, `workspace_test.ml`, `cli_test.ml` |
| `TM403` | `transaction_test.ml`, `workspace_test.ml`, `workspace_fs_test.ml`, `cli_test.ml` |
| `TM404` | `workspace_test.ml`, `discovery_test.ml`, `forest_compile_test.ml`, `cli_test.ml` |
| `TM500` | `cli_test.ml` |

Span/location correctness (half-open UTF-8 byte spans, 1-based Unicode scalar
line/column, tab width 4, path:line:column excerpts, deterministic sorting):
`source_test.ml` (`span_make`, `slice`), `diagnostic_test.ml` (`tab_excerpt`,
`cjk_marker`, sorting tests), `frontmatter_test.ml` (`utf8_scalar_byte_mapping`,
`tag_real_spans`).

### Parser Details (lines 766–809)

| Requirement | Test |
| --- | --- |
| Front-matter masking preserves byte offsets | `frontmatter_test.ml`; `source_test.ml` |
| YAML low-level libyaml offset adapter | `frontmatter_test.ml` (syntax-failure diagnostics); `TM002` |
| Cmarkit resolver contract (`[[...]]` = Text + shortcut Link + Text; `![` + link for embeds; odd/even backslash; `[alias][[id]]` never Wiki) | `wiki_test.ml` (full suite: `simple_wiki_link`, `wiki_embed`, `reference_link_not_wiki`, `escaped_not_wiki`, `double_backslash_is_wiki`, `three_backslashes_not_wiki`, `larger_bracket_run`, `right_bracket_run`, `left_bracket_run`, `escaped_pipe_no_split`, `pipe_with_even_backslashes`, `multiple_unescaped_pipes_explicit`) |
| Resolver idempotence (called twice on abandoned parse) | `wiki_test.ml` (`repeated_calls`, `second_call_same`) |
| Only tagged shortcut links with matching spans become Wiki nodes | `wiki_test.ml` (`normal_paragraph_wiki`, `cross_paragraph_not_wiki`) |
| IR built only after closed dialect validation | `compiler_test.ml`; `block_test.ml` |

### Testing Strategy / Golden and Rejected-Syntax Assertions

- **Every supported mapping has a golden assertion**: `compiler_test.ml`
  (`golden_complete`) asserts the complete fixture maps byte-for-byte to
  `fixtures/forester/complete.tree`, and `forester_6_test.ml` asserts each
  emitter individually (`emission_basic`, `emission_blocks`, `emission_links`,
  `emission_lists`, `emission_math`, `emission_metadata`, `emission_sections`,
  `emission_images`, `emission_edge`).
- **Every rejected syntax class has a diagnostic assertion**: `block_test.ml`
  (`gfm_table_rejected`, `task_marker_rejected`, `footnote_rejected`,
  `fenced_math_rejected`, `raw_html_block_rejected`, `nested_heading_rejected`,
  `display_math_in_*_rejected`, `embed_in_*_rejected`,
  `invalid_lang_token_rejected`, `multi_token_fence_rejected`),
  `inline_test.ml` (`raw_html_rejected`, `strikethrough_rejected`,
  `uri_javascript_rejected`, `uri_data_image_rejected`),
  `wiki_test.ml` (invalid-target/alias diagnostics), and `cli.t/run.t` (`TM102`,
  `TM202`, `TM203`, `TM204`).
- **Byte-determinism**: `compiler_test.ml` (`roundtrip_deterministic`);
  `workspace_test.ml` (`second_build_noop`).
- **No-write check guarantee**: `workspace_test.ml` (`first_check_missing_no_writes`,
  `clean_check_silent_identical_snapshots`); `cli.t/run.t` (silent clean check).
- **Environment independence**: the two suites that write outside the build
  directory resolve their scratch root with `Unix.realpath` at creation
  (`workspace_test.ml`, `workspace_fs_test.ml` `tmpdir`), because the workspace
  refuses an output root reached through a symbolic link and `$TMPDIR` is one on
  macOS. The cram help assertion names the format (`--help=plain`) rather than
  leaving it to `auto`, which renders through groff only where a pager exists.

## Not covered by a test

Behaviors the implementation has that no assertion currently pins down. They
are listed so the gap is a recorded one rather than an assumed pass.

| Behavior | Where it lives |
| --- | --- |
| Minting runs only after the forest compiles, so a build that fails leaves the sources unwritten | `workspace.ml` (`build`, the `compile` before `mint_addresses`) |
| `check` never mints, so a tree that states no `id` is checked under its filename identity and reads as `TM301` until `build` addresses it | `workspace.ml` (`check` has no mint step) |
| A build that rolls a journal forward does not mint on that pass | `workspace.ml` (`build`, recovery branch returns `minted = []`) |
| NFC/NFD normalisation is not applied to file names, so a name macOS stored decomposed does not match a reference typed composed | `forest_index.ml` (`by_filename` compares bytes) |

## Compatibility Job

`test/forester_compat.sh` runs generated fixtures through the pinned external
executable with `forester build --no-theme forest.toml`, fails on nonzero exit
or on a generated-source warning, and verifies `output/index.html` exists. The
fixture `test/fixtures/compat/trees-md/index.tree.md` covers every required
area:

| Area | Fixture content |
| --- | --- |
| Metadata | `date`, `taxon`, `authors` (`[[manual]]` + literal), `contributors` (`[[index]]` + literal), `tags`, `meta` |
| Nested subtrees | named `<!-- subtree: notes -->## Notes` + nested anonymous `###` |
| Links | native external link, `[[manual]]`, back-link `[[index]]` |
| Transclusion | standalone `![[manual]]` |
| Math | `$x^2 + y^2 = z^2$` and standalone `$$y = mx + b$$` |
| Lists | tight, loose, ordered starting at 7 |
| Code | inline hostile code, fenced `ocaml` with hostile punctuation |
| Images | external URL and local `images/x.svg` asset |
| Escaping | braces, parens, `%`, `#`, escaped brackets, trailing backslash, Unicode/CJK/emoji |

**Local status (Task 20):** the version gate could not be satisfied in this
development switch. The installed `forester` executable is opam `forester 2.0`
(a 5.0-era CLI that rejects `--version`), not the pinned `6.0~dev` binary at
`30b73641cef02433ee158db6ddc77f7b49de60be`. The compatibility script's
`version = 6.0~dev` gate therefore fails before any fixture is built; this is
the expected local outcome and the proof is owned by the CI job that installs
the pinned commit. The compiler-side behaviors the fixture exercises (emission
of every profile form, the no-warning constraint) are covered locally by
`forester_6_test.ml` and `compiler_test.ml` golden assertions.

## Acceptance Criteria

| Criterion | Evidence |
| --- | --- |
| Every documented supported input has a matching golden `.tree` output | `compiler_test.ml` `golden_complete` (byte-identical fixture) |
| Generated identities globally unique against known roots and named subtrees | `forest_index_test.ml` (`duplicate_generated_roots`, `root_versus_named_subtree`, `generated_versus_handwritten_root`); `TM201` |
| `build` creates only manifest-owned output; byte-deterministic | `workspace_test.ml` (`first_build_creates_output_and_manifest`, `second_build_noop`); `compiler_test.ml` `roundtrip_deterministic` |
| `check` returns 0 on a clean workspace and writes no files | `workspace_test.ml` (`first_check_missing_no_writes`, `clean_check_silent_identical_snapshots`); `cli.t/run.t` |
| Source/semantic/reference/asset/state errors return 1 with precise diagnostics, outputs unchanged | `cli.t/run.t` (`TM202`/`TM203`/`TM204`/`TM102` scenarios); `workspace_test.ml` (`source_error_leaves_output_unchanged`, `config_error_no_writes`) |
| Usage/config/manifest/journal/I/O/internal failures return 2 | `cli_test.ml` (exit codes); `cli.t/run.t` (usage + unsupported target) |
| Manually modified generated output never silently overwritten/deleted | `workspace_test.ml` (`manually_modified_protection`); `cli.t/run.t` (`TM302`) |
| Pinned external Forester compatibility test passes without generated-source warnings | CI job (`forester_compat.sh`), version-gated on `6.0~dev`; locally documented as gated |
| Existing handwritten content unchanged | SHA-256 of `trees/aboutme.tree`, `trees/index.tree`, `trees/navigation.tree`, `trees/research.tree`, `trees/dev/0001.tree` recorded before and verified after the fresh `check` run — unchanged (see Task 20 report) |

## Dependencies and Licensing

Covered by [`DEPENDENCIES.md`](./DEPENDENCIES.md): the resolved closure from
`opam list --installed --required-by tree-md --recursive`, per-package license
expressions from `opam show`, source URLs, runtime/build/test classification,
and the explicit confirmation that no linked dependency is AGPL/GPL/plain-LGPL
(any LGPL-expression linked package carries the `OCaml-LGPL-linking-exception`;
GPL packages `menhir` and `conf-pkg-config` are build tools whose licenses do
not propagate). Reproducibility is provided by `dune.lock/`.
