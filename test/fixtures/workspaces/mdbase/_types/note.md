---
kind: mdbase.type
name: note
version: 1

match:
  path_glob: "trees-md/**/*.tree.md"

schema:
  dialect: json-schema-2020-12
  value:
    $schema: "https://json-schema.org/draft/2020-12/schema"
    type: object
    required: [status]
    additionalProperties: true
    properties:
      status:
        type: string
        enum: [draft, published]

collection:
  read_defaults:
    taxon: Note
---

# Note

Every note under `trees-md/` states a status. The taxon it is published under
is the same for all of them, so it is defaulted here rather than repeated in
every file.
