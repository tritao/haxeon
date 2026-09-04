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

static bool same_type(hl_type *left, hl_type *right) {
	int i;
	if (left->kind != right->kind) return false;
	if (left->kind != HFUN && left->kind != HMETHOD) return true;
	if (left->fun->nargs != right->fun->nargs) return false;
	for (i = 0; i < left->fun->nargs; i++)
		if (!same_type(left->fun->args[i], right->fun->args[i])) return false;
	return same_type(left->fun->ret, right->fun->ret);
}

static hl_module *load_generation(vbyte *bytes, int length) {
	char *error = NULL;
	hl_code *code;
	hl_module *module;
	if (bytes == NULL || length <= 0) return NULL;
	code = hl_code_read(bytes, length, &error);
	if (code == NULL) return NULL;
	module = hl_module_alloc(code);
	if (module == NULL || !hl_module_init(module, 0)) {
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
	int i;
	if (loaded == NULL || indices == NULL || indices->at->kind != HI32 || indices->size == 0)
		return false;
	generation = load_generation(bytes, length);
	if (generation == NULL) return false;

	/* Validate the whole transaction before changing a live dispatch slot. */
	for (i = 0; i < indices->size; i++) {
		int findex = hl_aptr(indices, int)[i];
		hl_function *old_function = find_function(loaded->base, findex);
		hl_function *new_function = find_function(generation, findex);
		if (old_function == NULL || new_function == NULL ||
			!same_type(old_function->type, new_function->type)) {
			/* Initialized HL modules are globally registered, so retain this rejected
			   generation as well; unloading requires an upstream module-removal API. */
			return false;
		}
	}

	for (i = 0; i < indices->size; i++) {
		int findex = hl_aptr(indices, int)[i];
		loaded->base->functions_ptrs[findex] = generation->functions_ptrs[findex];
	}
	loaded->generations = (hl_module **)realloc(loaded->generations,
		sizeof(hl_module *) * (loaded->generation_count + 1));
	loaded->generations[loaded->generation_count++] = generation;
	return true;
}

DEFINE_PRIM(_ABSTRACT(realtime_module), load, _BYTES _I32);
DEFINE_PRIM(_I32, call_i32, _ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_BOOL, patch, _ABSTRACT(realtime_module) _BYTES _I32 _ARR);
