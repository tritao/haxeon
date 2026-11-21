/* The entry point of a program Haxeon compiled to C (docs/design/AOT_BACKEND.md). The generated image.c holds the module image,
 * the slot table, the call trampolines and the layouts the C code assumes. The runtime builds its types, globals, natives and
 * constants from the image with the fork's own module initialization, given the C functions as the module's code
 * (`hl_module_init_aot`: nothing is compiled), so the C code shares every layout decision with the JIT. */
#include <hl.h>
#include <hlmodule.h>

extern const unsigned long long hlc_image[]; // the image's bytes as little-endian words
extern const int hlc_image_size;
extern void *hlc_functions[];
extern const int hlc_slot_count;
extern const int hlc_entry;
extern const int hlc_global_count;
extern const int hlc_global_offsets[];
extern const int hlc_object_layouts[];
extern const int hlc_alloc_count;
extern const int hlc_alloc_types[];
extern hl_jit_alloc_data hlc_alloc_data[];
typedef struct { const char *key; void *(*call)( void *f, void **a, vdynamic *out ); void *wrap; } hlc_signature;
extern const hlc_signature hlc_signatures[];
extern const int hlc_signature_count;

void hlc_stack_init( hl_module *m, void **functions, int count );

hl_type *hlc_types;
unsigned char *hlc_globals;
void **hlc_slots;

static void hlc_fail( const char *message, int a, int b, int c ) {
	fprintf(stderr, "hlc: %s (%d, %d, %d)\n", message, a, b, c);
	exit(70);
}

/* The C calling shape of a value of type `t`, as the generator spells it (`HlcModule.shapeCode`). */
static char hlc_shape( hl_type *t ) {
	switch( t->kind ) {
	case HVOID: return 'v';
	case HBOOL: return 'b';
	case HUI8: return 'c';
	case HUI16: return 's';
	case HI32: case HENUMTAG: return 'i';
	case HI64: case HGUID: return 'l';
	case HF32: return 'f';
	case HF64: return 'd';
	default: return 'p';
	}
}

/* The trampolines of a function type's calling shape. */
static const hlc_signature *hlc_find_signature( hl_type *t ) {
	char key[256];
	int nargs = t->fun->nargs;
	if( nargs > 254 ) hl_error("Too many arguments for a call");
	key[0] = hlc_shape(t->fun->ret);
	for(int i=0;i<nargs;i++) key[i + 1] = hlc_shape(t->fun->args[i]);
	key[nargs + 1] = 0;
	int low = 0, high = hlc_signature_count - 1;
	while( low <= high ) {
		int middle = (low + high) >> 1, order = strcmp(hlc_signatures[middle].key, key);
		if( order == 0 ) return hlc_signatures + middle;
		if( order < 0 ) low = middle + 1; else high = middle - 1;
	}
	hl_fatal1("hlc: no call trampoline for the function shape %s", key);
	return NULL;
}

/* How the runtime calls a compiled function with arguments in memory (`hl_dyn_call`), as the JIT's `callback_c2hl`. */
static void *hlc_static_call( void *f, hl_type *t, void **args, vdynamic *out ) {
	return hlc_find_signature(t)->call(f, args, out);
}

/* The function a closure wrapped to type `t` calls (`hl_make_fun_wrapper`), as the JIT's `call_jit_hl2c`. */
static void *hlc_get_wrapper( hl_type *t ) {
	return hlc_find_signature(t)->wrap;
}

/* The struct offsets and global offsets the generated code was compiled with must be the runtime's. */
static void hlc_check_layouts( hl_module *m ) {
	for(int g=0;g<hlc_global_count;g++)
		if( m->globals_indexes[g] != hlc_global_offsets[g] )
			hlc_fail("global offset differs from the runtime's", g, hlc_global_offsets[g], m->globals_indexes[g]);
	const int *p = hlc_object_layouts;
	while( *p >= 0 ) {
		int type = *p++, count = *p++;
		hl_runtime_obj *rt = hl_get_obj_rt(hlc_types + type);
		for(int i=0;i<count;i++) {
			int field = *p++, offset = *p++;
			if( rt->fields_indexes[field] != offset )
				hlc_fail("field offset differs from the runtime's", type, field, offset);
		}
	}
}

// The program's arguments are the runtime's characters: UTF-16 on Windows, where the entry point is wmain (-municode).
#ifdef HL_WIN
int wmain( int argc, wchar_t *argv[] ) {
#else
int main( int argc, char *argv[] ) {
#endif
	vdynamic *ret;
	bool isExc = false;
	char *error = NULL;
	hl_global_init();
	hl_setup.sys_args = (pchar**)(argv + 1);
	hl_setup.sys_nargs = argc - 1;
	hl_sys_init();
	hl_register_thread(&ret);
	hl_code *code = hl_code_read((const unsigned char*)hlc_image, hlc_image_size, &error);
	if( code == NULL ) {
		fprintf(stderr, "hlc: invalid module image: %s\n", error ? error : "?");
		return 70;
	}
	hl_setup.static_call = hlc_static_call;
	hl_setup.get_wrapper = hlc_get_wrapper;
	hl_module *m = hl_module_alloc(code);
	if( m == NULL || !hl_module_init_aot(m, hlc_functions) ) {
		fprintf(stderr, "hlc: module initialization failed\n");
		return 70;
	}
	hlc_types = code->types;
	hlc_globals = m->globals_data;
	hlc_slots = m->functions_ptrs;
	hlc_check_layouts(m);
	hlc_stack_init(m, hlc_functions, hlc_slot_count);
	// The collector describes its allocation fast path for each type the code allocates inline; an empty descriptor allocates
	// through hl_alloc_obj.
	for(int i=0;i<hlc_alloc_count;i++)
		if( !hl_jit_alloc_supported() || !hl_jit_alloc_prepare(hlc_types + hlc_alloc_types[i], hlc_alloc_data + i) )
			memset(hlc_alloc_data + i, 0, sizeof(hl_jit_alloc_data));
	vclosure cl = { 0 };
	cl.t = code->functions[m->functions_indexes[hlc_entry]].type;
	cl.fun = hlc_functions[hlc_entry];
	ret = hl_dyn_call_safe(&cl, NULL, 0, &isExc);
	fflush(stdout);
	if( isExc ) {
		hl_print_uncaught_exception(ret);
		return 1;
	}
	return 0;
}
