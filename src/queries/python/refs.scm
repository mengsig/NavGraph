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
; A deeper chain keeps the innermost qualifier (`a.store.limit` -> "store"),
; exactly as the heuristic scanner does; the extractor derives the chain head
; from the tree and records it as `receiver_root`.
(attribute
  object: (attribute attribute: (identifier) @qualifier)
  attribute: (identifier) @ref)

(assignment left: (identifier) @ref.write)
(assignment left: (attribute
  object: (identifier) @qualifier
  attribute: (identifier) @ref.write))
(augmented_assignment left: (identifier) @ref.readwrite)
(augmented_assignment left: (attribute
  object: (identifier) @qualifier
  attribute: (identifier) @ref.readwrite))

; A constructor/function keyword label is a write of that parameter or field:
; `ItemCreate(title="Widget")` writes `ItemCreate.title`. The qualifier is the
; callee, matching how the heuristic scanner scopes the same site.
(call function: (identifier) @qualifier
  arguments: (argument_list (keyword_argument name: (identifier) @ref.write)))
(call function: (attribute attribute: (identifier) @qualifier)
  arguments: (argument_list (keyword_argument name: (identifier) @ref.write)))
