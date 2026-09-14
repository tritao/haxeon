#include <ffi.h>
#include <stdio.h>

#ifdef _MSC_VER
#define HAXEON_FFI_CDECL __cdecl
#else
#define HAXEON_FFI_CDECL
#endif

typedef int(HAXEON_FFI_CDECL *binary_function)(int, int);
static int callback_bias = 1;

static int
add(int left, int right)
{
	return left + right;
}

static void
add_callback(ffi_cif *cif, void *result, void **arguments, void *user_data)
{
	(void)cif;
	*(int *)result = *(int *)arguments[0] + *(int *)arguments[1] + *(int *)user_data;
}

int
main(void)
{
	ffi_cif cif;
	ffi_type *argument_types[] = {&ffi_type_sint, &ffi_type_sint};
	int left = 19;
	int right = 23;
	int result = 0;
	void *arguments[] = {&left, &right};
	ffi_closure *closure;
	void *closure_code = NULL;

	if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 2, &ffi_type_sint, argument_types) != FFI_OK)
		return 1;
	ffi_call(&cif, FFI_FN(add), &result, arguments);
	if (result != 42)
		return 2;

	closure = (ffi_closure *)ffi_closure_alloc(sizeof(*closure), &closure_code);
	if (closure == NULL || closure_code == NULL)
		return 3;
	if (ffi_prep_closure_loc(closure, &cif, add_callback, &callback_bias, closure_code) != FFI_OK) {
		ffi_closure_free(closure);
		return 4;
	}
	result = ((binary_function)closure_code)(left, right);
	ffi_closure_free(closure);
	if (result != 43) {
		fprintf(stderr, "libffi closure returned %d, expected 43\n", result);
		return 5;
	}
	return 0;
}
