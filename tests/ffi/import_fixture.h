#include <stdint.h>

typedef uint32_t sample_handle;
typedef const char *hxi_utf8;
typedef const char *hxi_nullable_utf8;
typedef int32_t (*sample_binary_callback)(int32_t, int32_t);
typedef void (*sample_visit_callback)(const struct sample_options *, void *);
#ifdef _WIN32
typedef int32_t (__stdcall *sample_stdcall_callback)(int32_t);
int32_t __stdcall sample_stdcall_function(int32_t value);
#endif

enum {
    SAMPLE_OK = 0,
    SAMPLE_FAILED = -1,
    SAMPLE_FLAG = 1u << 3
};

enum sample_result {
    SAMPLE_RESULT_OK = 0,
    SAMPLE_RESULT_FAILED = -1
};

typedef struct sample_options {
    uint32_t struct_size;
    const char *title;
    uint64_t reserved[2];
} sample_options;

int32_t sample_create(const sample_options *options, sample_handle *output);
int32_t sample_apply(sample_binary_callback callback, int32_t left, int32_t right);
int32_t sample_apply_nullable(sample_binary_callback _Nullable callback);
enum sample_result sample_check_result(enum sample_result value);
const char *sample_error(void);
int32_t sample_check_utf8(hxi_utf8 value, hxi_nullable_utf8 optional);
