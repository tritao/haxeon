#include <stddef.h>
#include <stdint.h>

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

typedef struct Entity {
	int32_t slot;
	int32_t generation;
} Entity;

_Static_assert(sizeof(Entity) == 8, "Entity size");
_Static_assert(_Alignof(Entity) == 4, "Entity alignment");
_Static_assert(offsetof(Entity, slot) == 0, "Entity.slot offset");
_Static_assert(offsetof(Entity, generation) == 4, "Entity.generation offset");
