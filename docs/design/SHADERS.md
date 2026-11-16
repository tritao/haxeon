# Shaders in Haxeon

Status: deferred plan, not scheduled. Shaders are written in GLSL and
cross-compiled by `sokol-shdc` through NativeKit's shader toolchain (NativeKit
ADR 0021). This plan records the long-term direction for authoring shaders
and the spike that would decide it, so the current toolchain is built as its
back end rather than replaced by it.

## Two audiences

- **Creators** (Beartooth Studio users) author materials, not shader code:
  parameters, palettes and field graphs, run by fixed shaders compiled at
  build time. That is portable to GLES3 and WebGL2, safe on a platform that
  loads untrusted content, and keeps GPU cost predictable. Restricted custom
  material functions may come later, built on the language chosen here.
- **Engine and platform developers** need a shader language. This plan is
  about them.

## Direction: a GPU subset of Haxeon

Engine shaders would be written in Haxeon and compiled by Haxeon's compiler:

- **One set of types.** Uniform blocks, vertex layouts and instance records
  are Haxeon structs used on both sides, with no generated mirror types.
  This extends [STRUCTS.md](STRUCTS.md)'s single declaration to the GPU.
- **One function on CPU and GPU.** Packing on the CPU and unpacking in a
  shader are the same code, and shader functions can be unit-tested on the
  CPU. Beartooth's ProceduralKit needs its GPU field VM to match its CPU
  field evaluator exactly; one source makes that parity structural.
- **The same tools:** the language server, diagnostics, formatting and
  hot reload.
- **Composition** of typed shader modules (fog, lighting, picking, ground
  following) instead of include files and define combinations, as Heaps'
  HXSL does for Haxe.

The subset excludes the garbage collector, closures, `Dynamic` and dynamic
dispatch. It keeps structs, math and fixed-width scalar types, fixed-size
arrays, functions, and generics resolved at compile time. A GPU entry point
is marked by an annotation, not a new keyword; what a shader means to a
renderer stays in libraries.

## Stages

1. **Now.** GLSL and `sokol-shdc` through NativeKit's toolchain, with
   bindings from reflection and generated Haxeon modules. Nothing below
   changes this path; it becomes the back end.
2. **Front end.** The compiler type-checks the GPU subset and emits
   Vulkan-style GLSL into the same toolchain, with reflection taken from its
   own type information. Diagnostics from `sokol-shdc` map back to Haxeon
   source lines.
3. **Migration.** New shaders are written in Haxeon; existing GLSL keeps
   working as another input to the toolchain.
4. **Later, if measured to help.** Direct SPIR-V emission; restricted Haxeon
   material functions for creators, sandboxed by the subset and by GPU
   budgets.

## Fallback: Slang

Slang gives modules, generics, interfaces, reflection and a language server
without compiler work, at the cost of a second language and no code shared
with Haxeon. Its GLES3 and WebGL2 output would go through SPIR-V and
SPIRV-Cross, which must be proven for these targets.

## Deciding spike

Write the same three shaders as a Haxeon GPU subset and in Slang:

- a chunk-batched map vertex shader with packed-vertex unpacking and an
  instance table;
- one field-VM operation from ProceduralKit;
- a UI solid-fill shader.

Compare lines of code, code shared with the CPU side, error quality, editor
support, GLES3 and WebGL2 output on both paths, and the compiler effort for
the Haxeon front end. Adopt the Haxeon subset if its front end fits a bounded
milestone; otherwise adopt Slang and keep generated binding types.

## Not decided here

- The annotation spelling for entry points and stage inputs and outputs.
- How shader modules compose: link-time selection, as HXSL does, or only
  compile-time variants.
- Whether creator material functions ever compile to shaders, or stay data
  for fixed shaders.
