; NavGraph-owned TypeScript/TSX local-binding set.

(required_parameter pattern: (identifier) @bind.name)
(required_parameter
  pattern: (identifier) @bind.name
  type: (type_annotation (_) @bind.type))
(optional_parameter pattern: (identifier) @bind.name)
(optional_parameter
  pattern: (identifier) @bind.name
  type: (type_annotation (_) @bind.type))

; Every declarator inside a callable is a local, typed or not: without the
; untyped case a local shadowing a module-level name resolves to the global.
(variable_declarator name: (identifier) @bind.name)
(variable_declarator name: (identifier) @bind.name type: (type_annotation (_) @bind.type))
(variable_declarator name: (identifier) @bind.name value: (new_expression) @bind.type)
(variable_declarator name: (identifier) @bind.name value: (call_expression) @bind.type)
