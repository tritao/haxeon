#include <stdint.h>

#define HXI_OUT __attribute__((annotate("hxi:out")))
#define HXI_INOUT __attribute__((annotate("hxi:inout")))
#define HXI_OUT_BUFFER(size) __attribute__((annotate("hxi:out_buffer")))
#define HXI_RETURNS_BORROWED_UTF8 __attribute__((annotate("hxi:returns_borrowed_utf8")))
#define HXI_UTF8 __attribute__((annotate("hxi:utf8")))
#define HXI_NULLABLE_UTF8 __attribute__((annotate("hxi:nullable_utf8")))
#define HXI_BORROWED __attribute__((annotate("hxi:borrowed")))
#define HXI_LENGTH_FIELD(size) __attribute__((annotate("hxi:length_field")))

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
    SAMPLE_FLAG = 1u << 3,
    SAMPLE_U32_MAX = 0xffffffffu
};

enum sample_result {
    SAMPLE_RESULT_OK = 0,
    SAMPLE_RESULT_FAILED = -1
};

typedef struct sample_options {
    uint32_t struct_size;
    const char *title HXI_NULLABLE_UTF8;
    uint64_t reserved[2];
} sample_options;

typedef struct sample_event {
    const void *data HXI_BORROWED HXI_LENGTH_FIELD(data_size);
    uint64_t data_size;
} sample_event;

int32_t sample_create(const sample_options *options, sample_handle *output HXI_OUT);
int32_t sample_read(uint8_t *_Nullable data HXI_OUT_BUFFER(size), uint32_t *size HXI_INOUT);
int32_t sample_apply(sample_binary_callback callback, int32_t left, int32_t right);
int32_t sample_apply_nullable(sample_binary_callback _Nullable callback);
enum sample_result sample_check_result(enum sample_result value);
const char *sample_error(void) HXI_RETURNS_BORROWED_UTF8;
int32_t sample_check_utf8(hxi_utf8 value, hxi_nullable_utf8 optional);
int32_t sample_check_annotated_utf8(const char *value HXI_UTF8,
                                    const char *optional HXI_NULLABLE_UTF8);
int32_t sample_paths(const char *const *paths, const char **out_path);
