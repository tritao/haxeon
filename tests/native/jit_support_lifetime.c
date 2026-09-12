#include <hl.h>
#include <hlmodule.h>
#include <jit.h>

#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	unsigned char *data;
	int length;
} test_bytes;

static char *append_suffix( const char *prefix, const char *suffix ) {
	size_t prefix_size = strlen(prefix);
	size_t suffix_size = strlen(suffix);
	char *path = (char*)malloc(prefix_size + suffix_size + 1);
	if( path == NULL ) return NULL;
	memcpy(path,prefix,prefix_size);
	memcpy(path + prefix_size,suffix,suffix_size + 1);
	return path;
}

static int read_file( const char *path, test_bytes *out ) {
	FILE *file = fopen(path,"rb");
	long length;
	if( file == NULL ) return 0;
	if( fseek(file,0,SEEK_END) != 0 || (length = ftell(file)) < 0 || length > INT_MAX || fseek(file,0,SEEK_SET) != 0 ) {
		fclose(file);
		return 0;
	}
	out->data = (unsigned char*)malloc((size_t)length);
	if( out->data == NULL || fread(out->data,1,(size_t)length,file) != (size_t)length ) {
		free(out->data);
		out->data = NULL;
		fclose(file);
		return 0;
	}
	out->length = (int)length;
	fclose(file);
	return 1;
}

static int read_function_id( const char *prefix, int *out ) {
	char *path = append_suffix(prefix,".id");
	FILE *file;
	int result;
	int ok;
	if( path == NULL ) return 0;
	file = fopen(path,"rb");
	free(path);
	if( file == NULL ) return 0;
	ok = fscanf(file,"%d",&result) == 1 && result >= 0;
	fclose(file);
	if( ok ) *out = result;
	return ok;
}

static int call_i32( hl_runtime_module *module, int function_id, int expected, const char *label ) {
	vdynamic *exception = NULL;
	int result = 0;
	hl_runtime_status status = hl_runtime_module_call_i32(module,function_id,&result,&exception);
	if( status != HL_RUNTIME_OK || result != expected ) {
		fprintf(stderr,"%s: call status %d, returned %d (expected %d)\n",label,(int)status,result,expected);
		return 0;
	}
	return 1;
}

static hl_runtime_module *load_fixture( const char *prefix, const char *label, int *function_id ) {
	char *code_path = append_suffix(prefix,".hl");
	char *identity_path = append_suffix(prefix,".hli");
	test_bytes code = {NULL,0}, identity = {NULL,0};
	hl_runtime_module *module = NULL;
	hl_runtime_status status;
	if( code_path == NULL || identity_path == NULL || !read_file(code_path,&code) || !read_file(identity_path,&identity)
		|| !read_function_id(prefix,function_id) ) {
		fprintf(stderr,"%s: could not read fixture files for %s\n",label,prefix);
		goto done;
	}
	status = hl_runtime_module_load(code.data,code.length,identity.data,identity.length,&module);
	if( status != HL_RUNTIME_OK ) {
		fprintf(stderr,"%s: module load failed with status %d\n",label,(int)status);
		module = NULL;
	}
done:
	free(code_path);
	free(identity_path);
	free(code.data);
	free(identity.data);
	return module;
}

static int release_module( hl_runtime_module **module, const char *label ) {
	hl_runtime_status status;
	if( *module == NULL ) return 1;
	hl_gc_major();
	status = hl_runtime_module_release(*module);
	if( status == HL_RUNTIME_RETIRE_BLOCKED ) {
		hl_gc_major();
		status = hl_runtime_module_release(*module);
	}
	if( status != HL_RUNTIME_OK ) {
		fprintf(stderr,"%s: module release failed with status %d\n",label,(int)status);
		return 0;
	}
	*module = NULL;
	return 1;
}

int main( int argc, char **argv ) {
	int stack_marker = 0;
	int owner_id, survivor_id;
	int passed = 0;
	hl_runtime_module *owner = NULL, *survivor = NULL;
	void *reuse_guard = NULL;
	if( argc != 3 ) {
		fprintf(stderr,"usage: %s <owner-prefix> <survivor-prefix>\n",argv[0]);
		return 2;
	}
	hl_global_init();
	hl_setup.file_path = argv[0];
	hl_setup.sys_args = (pchar**)(argv + 1);
	hl_setup.sys_nargs = argc - 1;
	hl_sys_init();
	hl_register_thread(&stack_marker);

	owner = load_fixture(argv[1],"owner module",&owner_id);
	if( owner == NULL || !call_i32(owner,owner_id,41,"owner module") || !release_module(&owner,"owner module") )
		goto done;

	/* Occupy the just-freed executable mapping so the next JIT allocation
	   cannot accidentally make a dangling trampoline pointer appear valid. */
	reuse_guard = hl_alloc_executable_memory(1 << 20);
	if( reuse_guard == NULL ) {
		fprintf(stderr,"could not reserve executable-address reuse guard\n");
		goto done;
	}

	survivor = load_fixture(argv[2],"survivor module",&survivor_id);
	if( survivor == NULL || !call_i32(survivor,survivor_id,42,"survivor module") || !release_module(&survivor,"survivor module") )
		goto done;
	passed = 1;
done:
	if( survivor != NULL ) release_module(&survivor,"survivor module cleanup");
	if( owner != NULL ) release_module(&owner,"owner module cleanup");
	if( reuse_guard != NULL ) hl_free_executable_memory(reuse_guard,1 << 20);
	hl_global_free();
	if( passed ) puts("PASS: C2HL support survives unloading its first module");
	return passed ? 0 : 1;
}
