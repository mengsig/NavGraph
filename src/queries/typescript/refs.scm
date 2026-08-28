; NavGraph-owned TypeScript/TSX reference set. Same offset-merge protocol as
; queries/python/refs.scm.

(identifier) @ref
(type_identifier) @ref

(call_expression function: (identifier) @ref.call)
(call_expression function: (member_expression
  object: (identifier) @qualifier
  property: (property_identifier) @ref.call))
(call_expression function: (member_expression
  object: (this) @qualifier
  property: (property_identifier) @ref.call))
(member_expression object: (this) @qualifier property: (property_identifier) @ref)
(call_expression function: (member_expression
  object: (member_expression property: (property_identifier) @qualifier)
  property: (property_identifier) @ref.call))

(new_expression constructor: (identifier) @ref.call)

(member_expression object: (identifier) @qualifier property: (property_identifier) @ref)
; A deeper chain keeps the innermost qualifier (`a.store.limit` -> "store");
; the extractor derives the chain head from the tree as `receiver_root`.
(member_expression
  object: (member_expression property: (property_identifier) @qualifier)
  property: (property_identifier) @ref)

(assignment_expression left: (identifier) @ref.write)
(assignment_expression left: (member_expression
  object: (identifier) @qualifier
  property: (property_identifier) @ref.write))
(augmented_assignment_expression left: (identifier) @ref.readwrite)
(augmented_assignment_expression left: (member_expression
  object: (identifier) @qualifier
  property: (property_identifier) @ref.readwrite))
