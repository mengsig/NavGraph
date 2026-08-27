; NavGraph-owned Python reference set.
;
; `(identifier) @ref` is the broad sweep — the heuristic scanner also considers
; every identifier token. The narrower patterns refine the SAME byte offset with
; a call/write/qualifier, and the extractor merges by offset, so nothing is
; counted twice.

(identifier) @ref

(call function: (identifier) @ref.call)
(call function: (attribute
  object: (identifier) @qualifier
  attribute: (identifier) @ref.call))
(call function: (attribute
  object: (attribute attribute: (identifier) @qualifier)
  attribute: (identifier) @ref.call))

(attribute object: (identifier) @qualifier attribute: (identifier) @ref)

(assignment left: (identifier) @ref.write)
(assignment left: (attribute
  object: (identifier) @qualifier
  attribute: (identifier) @ref.write))
(augmented_assignment left: (identifier) @ref.readwrite)
(augmented_assignment left: (attribute
  object: (identifier) @qualifier
  attribute: (identifier) @ref.readwrite))
