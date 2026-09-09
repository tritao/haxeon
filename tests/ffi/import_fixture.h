#include <stdint.h>

typedef uint32_t sample_handle;

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
enum sample_result sample_check_result(enum sample_result value);
const char *sample_error(void);
