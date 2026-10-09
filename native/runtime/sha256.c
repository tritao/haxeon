#include "../shared/sha256.h"

HL_PRIM realtime_bytes *HL_NAME(__sha256)(realtime_bytes *input) {
	if (input == NULL) hl_error("SHA-256 input cannot be null");
	realtime_bytes *output = realtime_bytes_make(32);
	uint32_t scratch[104];
	realtime_sha256_digest(input->data, (size_t)input->length, output->data, scratch);
	return output;
}

/* Standard Haxe's HashLink Bytes ABI is used by the separately compiled build tools. */
HL_PRIM void HL_NAME(__sha256_raw)(vbyte *input, int length, vbyte *output) {
	if (length < 0 || (input == NULL && length != 0) || output == NULL) hl_error("Invalid SHA-256 buffer");
	uint32_t scratch[104];
	realtime_sha256_digest(input, (size_t)length, output, scratch);
}
