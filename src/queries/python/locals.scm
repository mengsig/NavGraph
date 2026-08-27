; NavGraph-owned Python local-binding set: `name -> type` pairs the resolver uses
; to type a receiver. Parameters bind even without an annotation, so a bare use
; of a parameter name is a local rather than a same-named global.

(parameters (identifier) @bind.name)
(parameters (typed_parameter (identifier) @bind.name type: (type) @bind.type))
(parameters (default_parameter name: (identifier) @bind.name))
(parameters (typed_default_parameter name: (identifier) @bind.name type: (type) @bind.type))

(assignment left: (identifier) @bind.name type: (type) @bind.type)
(assignment left: (identifier) @bind.name right: (call) @bind.type)
