#include <stdint.h>

typedef struct audit_drift {
#if defined(_WIN32)
    uint64_t value;
#else
    uint32_t value;
#endif
} audit_drift;
