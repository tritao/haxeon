#include <stdint.h>

/** An opaque resource identifier used by the documentation fixture. */
typedef uint32_t docs_handle;

/** Display mode accepted by the fixture API. */
enum docs_mode {
    /** Use the platform default mode. */
    DOCS_MODE_DEFAULT = 0,
    /** Force the compact mode. */
    DOCS_MODE_COMPACT = 1
};

/* Clang attaches a documented enumerator's comment to the undocumented ones after it too; only the first is documented. */
enum docs_level {
    /** The documented level. */
    DOCS_LEVEL_LOW = 0,
    DOCS_LEVEL_MEDIUM = 1,
    DOCS_LEVEL_HIGH = 2
};

/** Options supplied when creating a documented resource. */
typedef struct docs_options {
    /** Number of entries to reserve. */
    uint32_t count;
    /** Optional UTF-8 label copied by the implementation. */
    const char *label;
} docs_options;

/**
 * Creates a documented resource.
 *
 * @param options Creation options; the label is copied before returning.
 * @return DOCS_OK on success, or a negative error code.
 */
int32_t docs_create(const docs_options *options);
