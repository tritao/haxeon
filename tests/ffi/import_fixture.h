#include <stdint.h>

typedef uint32_t sample_handle;

enum {
    SAMPLE_OK = 0,
    SAMPLE_FAILED = -1,
    SAMPLE_FLAG = 1u << 3
};

typedef struct sample_options {
    uint32_t struct_size;
    const char *title;
    uint64_t reserved[2];
} sample_options;

int32_t sample_create(const sample_options *options, sample_handle *output);
const char *sample_error(void);
