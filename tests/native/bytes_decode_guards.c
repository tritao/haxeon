#define HL_NAME(n) bytes_decode_guard_##n
#include <hl.h>

/* Mirrors the Bytes prefix in native/runtime/core.c to mutate an existing payload. */
typedef struct {
	void (*finalize)(void*);
	vbyte *data;
	int length;
} bytes_prefix;

HL_API void hl_gc_set_profile_allocation_callback(void (*callback)(hl_type*,int,int,void*));
static bytes_prefix *source;
static int calls;

static void mutate_source(hl_type *type, int size, int allocated, void *caller) {
	(void)type; (void)size; (void)allocated; (void)caller;
	if (source != NULL) {
		source->data[0] = 'Z';
		calls++;
		hl_gc_set_profile_allocation_callback(NULL);
		hl_remove_root((void**)&source);
		source = NULL;
	}
}

HL_PRIM void HL_NAME(arm)(bytes_prefix *bytes) {
	if (source != NULL) hl_error("Byte snapshot guard already armed");
	if (bytes == NULL || bytes->length == 0) hl_error("Byte snapshot guard requires a payload");
	source = bytes;
	calls = 0;
	hl_add_root((void**)&source);
	hl_gc_set_profile_allocation_callback(mutate_source);
}

HL_PRIM int HL_NAME(disarm)(void) {
	hl_gc_set_profile_allocation_callback(NULL);
	if (source != NULL) {
		hl_remove_root((void**)&source);
		source = NULL;
	}
	return calls;
}

DEFINE_PRIM(_VOID,arm,_ABSTRACT(realtime_bytes));
DEFINE_PRIM(_I32,disarm,_NO_ARG);
