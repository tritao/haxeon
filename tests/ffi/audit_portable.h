#include <stdint.h>

typedef uint32_t audit_handle;

typedef struct audit_options {
    uint32_t struct_size;
    uint32_t flags;
    const char *name;
    uint64_t reserved[2];
} audit_options;

int32_t audit_open(const audit_options *options, audit_handle *out_handle);
