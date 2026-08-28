; NavGraph-owned Python local-binding set: `name -> type` pairs the resolver uses
; to type a receiver. Parameters bind even without an annotation, so a bare use
; of a parameter name is a local rather than a same-named global.

(parameters (identifier) @bind.name)
(parameters (typed_parameter (identifier) @bind.name type: (type) @bind.type))
(parameters (default_parameter name: (identifier) @bind.name))
(parameters (typed_default_parameter name: (identifier) @bind.name type: (type) @bind.type))

; Every assignment target inside a callable is a local, typed or not: without
; the untyped case a local shadowing a module-level name resolves to the global.
(assignment left: (identifier) @bind.name)
(assignment left: (identifier) @bind.name type: (type) @bind.type)
(assignment left: (identifier) @bind.name right: (call) @bind.type)
