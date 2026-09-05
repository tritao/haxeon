# Reload implementation baseline

Recorded 2026-09-05 before step 1 changes.

## Revisions

- realtime-haxe: `2d3e8e165d40a420f56b60191761637c67b62915`
- pinned HashLink fork: `cee2a986b58f47141c0d4c635faed28b6c720ffc`
- pre-existing untracked planning documents: `ORDERED_IMPLEMENTATION_PLAN.md`, `REPOSITORY_DESIGN_REVIEW.md`, and `TYPE_SYSTEM_DESIGN_PLAN.md`

## Passing gates

- `./scripts/test-poc.sh`
  - formatting and differential tests
  - compiler, module, language-service, protocol, and runtime-domain tests
  - representative plugin workload
  - source-program and native runtime integration tests
- `./test-hot-reload.sh`
  - live selective patching, atomic publication, and bounded JIT allocation
- `./scripts/bootstrap-status.sh`
  - completed successfully as a readiness measurement

No baseline test failure was observed.

## Existing coverage and gaps

The repository already has a representative deterministic plugin facade and live
HashLink patch tests. The HashLink fork has transactional function patching and
bounded JIT ownership. Type-table growth still fails closed because live code can
retain direct pointers into the contiguous type table; the non-moving metadata
arena required by later plan steps is not complete.

Compiler identity state was HCS v2. It retained the module ID, stable function
IDs, and nominal type identity state, but omitted the ABI descriptor, compiler
revision, HashLink slot layout, constant/type table baselines, and runtime
acknowledgement state. Compilation also mutated caches, ABI state, and assembler
revision before patch encoding had completed.

The bootstrap dashboard measured 60 source files: 24 lexed, 1 parsed, 0 typed,
and 0 functions. These are expected readiness gaps rather than baseline failures.
