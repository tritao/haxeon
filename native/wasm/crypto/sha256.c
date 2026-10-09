#include "../../shared/sha256.h"

__attribute__((export_name("haxeon_sha256")))
void haxeon_sha256(const unsigned char *input, uint32_t length, unsigned char *output,
    uint32_t output_length, uint32_t *scratch, uint32_t scratch_length) {
  if (output_length != 32 || scratch_length < 416 || ((uintptr_t)scratch & 3) != 0) __builtin_trap();
  realtime_sha256_digest(input, length, output, scratch);
}
