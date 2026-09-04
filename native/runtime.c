#define HL_NAME(n) realtime_##n
#include <hl.h>
#include <hlmodule.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	hl_module *base;
	hl_mutex *lock;
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
	loaded->lock = hl_mutex_alloc(true);
	hl_add_root(&loaded->lock);
	return loaded;
}

HL_PRIM int HL_NAME(call_i32)(realtime_module *loaded, int findex) {
	hl_function *function;
	vclosure closure;
	vdynamic *result;
	bool is_exception = false;
	if (loaded == NULL) hl_error("Runtime module is null");
	hl_mutex_acquire(loaded->lock);
	function = find_function(loaded->base, findex);
	if (function == NULL || function->type->kind != HFUN ||
		function->type->fun->nargs != 0 || function->type->fun->ret->kind != HI32) {
		hl_mutex_release(loaded->lock);
		hl_error("Stable slot is not a zero-argument Int function");
	}
	closure.t = function->type;
	closure.fun = loaded->base->functions_ptrs[findex];
	closure.hasValue = 0;
	closure.value = NULL;
	result = hl_dyn_call_safe(&closure, NULL, 0, &is_exception);
	hl_mutex_release(loaded->lock);
	if (is_exception) hl_throw(result);
	return result->v.i;
}

HL_PRIM bool HL_NAME(patch)(realtime_module *loaded, vbyte *bytes, int length) {
	const char *error = NULL;
	hl_patch *patch;
	bool result;
	if (loaded == NULL)
		return false;
	hl_mutex_acquire(loaded->lock);
	patch=hl_patch_read(bytes,length,&error);
	result=patch!=NULL && hl_module_apply_patch(loaded->base,patch,&error);
	hl_patch_free(patch);
	hl_mutex_release(loaded->lock);
	return result;
}

HL_PRIM int HL_NAME(allocation_count)(realtime_module *loaded) {
	return loaded == NULL ? 0 : 1 + hl_module_patch_allocation_count(loaded->base);
}

HL_PRIM int HL_NAME(patch_jit_count)(realtime_module *loaded) {
	return loaded == NULL ? 0 : loaded->base->patch_jit_count;
}

HL_PRIM void HL_NAME(dispose)(realtime_module *loaded) {
	if (loaded == NULL) return;
	hl_mutex_acquire(loaded->lock);
	hl_module_unload(loaded->base);
	hl_mutex_release(loaded->lock);
	hl_remove_root(&loaded->lock);
	hl_mutex_free(loaded->lock);
	free(loaded);
}

HL_PRIM int HL_NAME(inspect_patch)(vbyte *bytes, int length) {
	const char *error = NULL;
	hl_patch *patch = hl_patch_read(bytes,length,&error);
	int summary;
	if (patch == NULL || patch->base_revision > 0x3FF || patch->revision > 0x3FF || patch->function_count > 0xFFF) {
		hl_patch_free(patch);
		return -1;
	}
	summary = (patch->base_revision << 22) | (patch->revision << 12) | patch->function_count;
	hl_patch_free(patch);
	return summary;
}

DEFINE_PRIM(_ABSTRACT(realtime_module), load, _BYTES _I32);
DEFINE_PRIM(_I32, call_i32, _ABSTRACT(realtime_module) _I32);
DEFINE_PRIM(_BOOL, patch, _ABSTRACT(realtime_module) _BYTES _I32);
DEFINE_PRIM(_I32, allocation_count, _ABSTRACT(realtime_module));
DEFINE_PRIM(_I32, patch_jit_count, _ABSTRACT(realtime_module));
DEFINE_PRIM(_VOID, dispose, _ABSTRACT(realtime_module));
DEFINE_PRIM(_I32, inspect_patch, _BYTES _I32);
