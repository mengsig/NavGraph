; NavGraph-owned TypeScript/TSX definition set. One query set drives both
; grammars: tsx is a separate generated parser but the same node vocabulary.
;
; Capture protocol: see queries/python/defs.scm and src/ts_backend.zig.

(function_declaration name: (identifier) @name) @def.function
(function_declaration "async" @mod.async name: (identifier) @name) @def.function
(generator_function_declaration name: (identifier) @name) @def.function
(function_signature name: (identifier) @name) @def.function

(class_declaration name: (type_identifier) @name) @def.class
(abstract_class_declaration name: (type_identifier) @name) @def.class

(method_definition name: (property_identifier) @name) @def.method
(method_definition "async" @mod.async name: (property_identifier) @name) @def.method
(method_definition "static" @mod.static name: (property_identifier) @name) @def.method
(method_definition "get" @mod.getter name: (property_identifier) @name) @def.method
(method_definition "set" @mod.setter name: (property_identifier) @name) @def.method
(method_signature name: (property_identifier) @name) @def.method
(abstract_method_signature name: (property_identifier) @name @mod.abstract) @def.method

; Class fields, with their declared type when the source spells one.
(public_field_definition name: (property_identifier) @name) @def.field
(public_field_definition "static" @mod.static name: (property_identifier) @name) @def.field
(public_field_definition
  name: (property_identifier) @name
  type: (type_annotation (_) @type)) @def.field
(public_field_definition
  name: (property_identifier) @name
  value: (_) @init) @def.field

; Interface members and type-literal members — zero of these reach the index
; through the heuristic scanner.
(interface_declaration name: (type_identifier) @name) @def.interface
(property_signature name: (property_identifier) @name) @def.field
(property_signature
  name: (property_identifier) @name
  type: (type_annotation (_) @type)) @def.field
(method_signature name: (property_identifier) @name) @def.field

(type_alias_declaration name: (type_identifier) @name) @def.type

(enum_declaration name: (identifier) @name) @def.enum
(enum_body (property_identifier) @name @def.field)
(enum_body (enum_assignment name: (property_identifier) @name)) @def.field

; `const x = …` / `let x = …`. The kind (constant vs variable) follows the
; declaration keyword, which lexical_declaration spells; `var` is a variable.
(lexical_declaration (variable_declarator name: (identifier) @name)) @def.variable
(lexical_declaration
  (variable_declarator name: (identifier) @name value: (_) @init)) @def.variable
(lexical_declaration
  (variable_declarator
    name: (identifier) @name
    value: (arrow_function "async" @mod.async))) @def.variable
(lexical_declaration
  (variable_declarator
    name: (identifier) @name
    type: (type_annotation (_) @type))) @def.variable
(variable_declaration (variable_declarator name: (identifier) @name)) @def.variable

; `export` marks the symbol public regardless of its name.
(export_statement declaration: (_) @exported)

; A re-export barrel (`export { X } from './y'`) is an import edge too.
(export_statement source: (string) @from.path) @def.import

(import_statement source: (string) @from.path) @def.import
(import_statement
  (import_clause (identifier) @name)
  source: (string) @path) @def.import
(import_statement
  (import_clause (namespace_import (identifier) @name))
  source: (string) @path) @def.import
