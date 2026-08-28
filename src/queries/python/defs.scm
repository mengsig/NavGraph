; NavGraph-owned Python definition set.
;
; Capture protocol (src/ts_backend.zig): each pattern captures exactly one
; @def.<kind> node — the definition's span — plus @name. Optional @type, @init,
; @recv, @path, @decorators refine it. Patterns deliberately overlap: matches on
; the same node are merged, so one narrow pattern can add @type to a broad one.
; Kinds that depend on the enclosing scope (function -> method, variable ->
; field) are refined in Zig, exactly as the heuristic scanner decides them.

(function_definition name: (identifier) @name) @def.function
(function_definition "async" @mod.async name: (identifier) @name) @def.function

(decorated_definition
  definition: (function_definition name: (identifier) @name) @def.function) @decorators

(class_definition name: (identifier) @name) @def.class

(decorated_definition
  definition: (class_definition name: (identifier) @name) @def.class) @decorators

; Module- and class-level bindings. Assignments inside a function body are local
; variables, not definitions, and are dropped in Zig.
(assignment left: (identifier) @name) @def.variable
(assignment left: (identifier) @name type: (type) @type) @def.variable
(assignment left: (identifier) @name right: (_) @init) @def.variable

; `self.x = …` instance fields — the heuristic scanner indexes none of these.
; The span is the `self.x` node, so it ends at the `=` and never swallows the
; initializer (which would lose the constructor call as an edge).
(assignment
  left: (attribute object: (identifier) @recv attribute: (identifier) @name) @def.field)
(assignment
  left: (attribute object: (identifier) @recv attribute: (identifier) @name) @def.field
  type: (type) @type)
(assignment
  left: (attribute object: (identifier) @recv attribute: (identifier) @name) @def.field
  right: (_) @init)

; Imports. `name` is the bound alias; a dotted module with no alias binds nothing
; and is derived from @path in Zig.
(import_statement name: (dotted_name) @path) @def.import
(import_statement
  name: (aliased_import name: (dotted_name) @path alias: (identifier) @name)) @def.import
; `from mod import X` records the module edge only — it binds no module name.
(import_from_statement module_name: (dotted_name) @from.path) @def.import
(import_from_statement module_name: (relative_import) @from.path) @def.import
; `from __future__ import x` is its own grammar rule with no module_name field.
(future_import_statement "__future__" @from.path) @def.import
