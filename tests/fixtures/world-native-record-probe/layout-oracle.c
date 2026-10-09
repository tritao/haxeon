#include <stddef.h>

typedef struct Transform {
	double x;
	double y;
	double z;
} Transform;

_Static_assert(sizeof(Transform) == 24, "Transform size");
_Static_assert(_Alignof(Transform) == 8, "Transform alignment");
_Static_assert(offsetof(Transform, x) == 0, "Transform.x offset");
_Static_assert(offsetof(Transform, y) == 8, "Transform.y offset");
_Static_assert(offsetof(Transform, z) == 16, "Transform.z offset");
