package compiler.backend.wasm;

import compiler.backend.Backend.BackendResult;

/** The emitted artifact and the exact runtime identities selected during target lowering. */
typedef WasmCompilation = {
	final artifact:BackendResult;
	final runtimeTypeIds:WasmTypeIdPlan;
}
