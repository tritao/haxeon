#define HL_NAME(n) realtime_##n
#include <hl.h>
#include <hlmodule.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	hl_module *base;
	hl_module **generations;
	int generation_count;
} realtime_module;

static hl_function *find_function(hl_module *module, int findex) {
	int i;
	for (i = 0; i < module->code->nfunctions; i++) {
		hl_function *function = module->code->functions + i;
		if (function->findex == findex) return function;
	}
	return NULL;
}

static hl_module *load_generation(vbyte *bytes, int length) {
	char *error = NULL;
	hl_code *code;
	hl_module *module;
	if (bytes == NULL || length <= 0) return NULL;
	code = hl_code_read(bytes, length, &error);
	if (code == NULL) return NULL;
	module = hl_module_alloc(code);
	if (module == NULL || !hl_module_init(module, HL_MODULE_PATCHABLE)) {
		if (module != NULL) hl_module_free(module);
		hl_code_free(code);
		return NULL;
	}
	/* hl_module_alloc owns the allocations required by the initialized module. */
	hl_code_free(code);
	return module;
}

HL_PRIM realtime_module *HL_NAME(load)(vbyte *bytes, int length) {
	realtime_module *loaded;
	hl_module *module = load_generation(bytes, length);
	if (module == NULL) return NULL;
	loaded = (realtime_module *)malloc(sizeof(realtime_module));
	loaded->base = module;
	loaded->generations = NULL;
	loaded->generation_count = 0;
	return loaded;
}

HL_PRIM int HL_NAME(call_i32)(realtime_module *loaded, int findex) {
	hl_function *function;
	vclosure closure;
	vdynamic *result;
	if (loaded == NULL) hl_error("Runtime module is null");
	function = find_function(loaded->base, findex);
	if (function == NULL || function->type->kind != HFUN ||
		function->type->fun->nargs != 0 || function->type->fun->ret->kind != HI32)
		hl_error("Stable slot is not a zero-argument Int function");
	closure.t = function->type;
	closure.fun = loaded->base->functions_ptrs[findex];
	closure.hasValue = 0;
	closure.value = NULL;
	result = hl_dyn_call(&closure, NULL, 0);
	return result->v.i;
}

HL_PRIM bool HL_NAME(patch)(realtime_module *loaded, vbyte *bytes, int length, varray *indices) {
	hl_module *generation;
	if (loaded == NULL || indices == NULL || indices->at->kind != HI32 || indices->size == 0)
		return false;
	generation = load_generation(bytes, length);
	if (generation == NULL) return false;

	if (!hl_module_patch_slots(loaded->base, generation,
		hl_aptr(indices, int), indices->size)) return false;
	loaded->generations = (hl_module **)realloc(loaded->generations,
		sizeof(hl_module *) * (loaded->generation_count + 1));
	loaded->generations[loaded->generation_count++] = generation;
	return true;
}

DEFINE_PRIM(_ABSTRACT(realtime_module), load, _BYTES _I32);
DEFINE_PRIM(_I32, call_i32, _ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_BOOL, patch, _ABSTRACT(realtime_module) _BYTES _I32 _ARR);
