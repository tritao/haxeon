#include <stdint.h>

#if defined(PACKED_RECORD)
typedef struct packed_record { uint8_t tag; uint32_t value; } __attribute__((packed)) packed_record;
#elif defined(ALIGNED_FIELD)
typedef struct aligned_field { uint8_t tag; _Alignas(16) uint32_t value; } aligned_field;
#elif defined(PRAGMA_PACK)
#pragma pack(push, 1)
typedef struct pragma_packed { uint8_t tag; uint32_t value; } pragma_packed;
#pragma pack(pop)
#elif defined(BIT_FIELD)
typedef struct bit_field { uint32_t low : 3; uint32_t value; } bit_field;
#elif defined(ALIGNED_TYPEDEF)
typedef uint32_t aligned_u32 __attribute__((aligned(8)));
#endif
