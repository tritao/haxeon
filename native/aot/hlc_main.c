/* The entry point of a program Haxeon compiled to C (docs/design/AOT_BACKEND.md). The generated image.c holds the module image,
 * the slot table and the layouts the C code assumes. The runtime builds its types, globals, natives and constants from the image
 * with the fork's own module initialization, so the C code shares every layout decision with the JIT; the function slots are then
 * pointed at the C functions, before any object prototype is built from them. */
#include <hl.h>
#include <hlmodule.h>

extern const unsigned char hlc_image[];
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

hl_type *hlc_types;
unsigned char *hlc_globals;
void **hlc_slots;

static void hlc_fail( const char *message, int a, int b, int c ) {
	fprintf(stderr, "hlc: %s (%d, %d, %d)\n", message, a, b, c);
	exit(70);
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

int main( int argc, char *argv[] ) {
	vdynamic *ret;
	bool isExc = false;
	char *error = NULL;
	hl_global_init();
	hl_setup.sys_args = (pchar**)(argv + 1);
	hl_setup.sys_nargs = argc - 1;
	hl_sys_init();
	hl_register_thread(&ret);
	hl_code *code = hl_code_read(hlc_image, hlc_image_size, &error);
	if( code == NULL ) {
		fprintf(stderr, "hlc: invalid module image: %s\n", error ? error : "?");
		return 70;
	}
	hl_module *m = hl_module_alloc(code);
	if( m == NULL || !hl_module_init(m, 0) ) {
		fprintf(stderr, "hlc: module initialization failed\n");
		return 70;
	}
	hlc_types = code->types;
	hlc_globals = m->globals_data;
	hlc_slots = m->functions_ptrs;
	for(int i=0;i<hlc_slot_count;i++)
		if( hlc_functions[i] ) m->functions_ptrs[i] = hlc_functions[i];
	hlc_check_layouts(m);
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
