# Vendored format library

This directory contains HaxeFoundation/format at revision
`775a06f0a7aa64cbd060b5c3ba62f65d7fed684a` (BSD 2-Clause).

Haxeon maintains two changes in `format/hl/Reader.hx`:

- Accept HashLink bytecode version 7. Its original v6 payload remains readable;
  version 7 appends debug sections after that payload.
- Resolve object and struct superclass references after all types are read,
  as the reader already does for fields and function signatures. This permits
  valid forward references in Haxeon bytecode.

Use this directory as a Haxe classpath when compiling HashLink inspection
tools. The vendored source avoids changing an installed haxelib checkout at
runtime. Changes to this copy should be proposed upstream before the next
dependency refresh.
