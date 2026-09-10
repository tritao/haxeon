#include "import_fixture.h"

typedef struct dependency_extra {
    int32_t value;
} dependency_extra;

int32_t dependency_use(sample_handle value, dependency_extra extra);
