#include <stdint.h>

/** Handle returned by the portable audit fixture. */
typedef uint32_t audit_handle;

/** Options accepted by the portable audit fixture. */
typedef struct audit_options {
    /** Structure size supplied by the caller. */
    uint32_t struct_size;
    /** Feature flags selected by the caller. */
    uint32_t flags;
    /** Optional UTF-8 name. */
    const char *name;
    /** Reserved for future options. */
    uint64_t reserved[2];
} audit_options;

/** Opens a fixture handle using the supplied options. */
int32_t audit_open(const audit_options *options, audit_handle *out_handle);
