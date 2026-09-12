HL_PRIM int64_t HL_NAME(__int64_parse)(vbyte *value) {
	if (value == NULL)
		hl_error("Cannot parse a null Int64 string");
	char *text = realtime_utf8_copy(value), *end = NULL;
	errno = 0;
	long long parsed = strtoll(text, &end, 10);
	bool valid = errno != ERANGE && end != text && *end == 0;
	free(text);
	if (!valid)
		hl_error("Invalid Int64 string");
	return (int64_t)parsed;
}

HL_PRIM vbyte *HL_NAME(__int64_to_string)(int64_t value) {
	char text[32];
	snprintf(text, sizeof(text), "%lld", (long long)value);
	return realtime_string_from_utf8(text);
}

HL_PRIM int64_t HL_NAME(__int64_of_int)(int value) { return (int64_t)value; }
HL_PRIM int64_t HL_NAME(__int64_from_float)(double value) { return (int64_t)value; }
HL_PRIM int64_t HL_NAME(__int64_make)(int high, int low) { return (int64_t)(((uint64_t)(uint32_t)high << 32) | (uint32_t)low); }
HL_PRIM int64_t HL_NAME(__int64_add)(int64_t left, int64_t right) { return left + right; }
HL_PRIM int64_t HL_NAME(__int64_sub)(int64_t left, int64_t right) { return left - right; }
HL_PRIM int64_t HL_NAME(__int64_and)(int64_t left, int64_t right) { return left & right; }
HL_PRIM int64_t HL_NAME(__int64_or)(int64_t left, int64_t right) { return left | right; }
HL_PRIM int64_t HL_NAME(__int64_xor)(int64_t left, int64_t right) { return left ^ right; }
HL_PRIM int64_t HL_NAME(__int64_shl)(int64_t value, int shift) {
	return shift < 0 || shift >= 64 ? 0 : (int64_t)((uint64_t)value << shift);
}
HL_PRIM int64_t HL_NAME(__int64_shr)(int64_t value, int shift) {
	if (shift < 0 || shift >= 64)
		return value < 0 ? -1 : 0;
	if (shift == 0)
		return value;
	uint64_t shifted = (uint64_t)value >> shift;
	if (value < 0)
		shifted |= UINT64_MAX << (64 - shift);
	return (int64_t)shifted;
}
HL_PRIM int64_t HL_NAME(__int64_ushr)(int64_t value, int shift) {
	return shift < 0 || shift >= 64 ? 0 : (int64_t)((uint64_t)value >> shift);
}
HL_PRIM int HL_NAME(__int64_compare)(int64_t left, int64_t right) { return left < right ? -1 : left > right ? 1 : 0; }
HL_PRIM int HL_NAME(__int64_unsigned_compare)(int64_t left, int64_t right) {
	uint64_t unsigned_left = (uint64_t)left, unsigned_right = (uint64_t)right;
	return unsigned_left < unsigned_right ? -1 : unsigned_left > unsigned_right ? 1 : 0;
}
