typedef struct _ereg realtime_ereg;

extern realtime_ereg *hl_regexp_new_options(vbyte *pattern, vbyte *options);
extern bool hl_regexp_match(realtime_ereg *expression, vbyte *value, int position, int length);
extern int hl_regexp_matched_pos(realtime_ereg *expression, int group, int *length);
extern int hl_regexp_matched_num(realtime_ereg *expression);

HL_PRIM realtime_ereg *HL_NAME(__regexp_new)(vbyte *pattern, vbyte *options) {
	return hl_regexp_new_options(pattern, options);
}

HL_PRIM bool HL_NAME(__regexp_match)(realtime_ereg *expression, vbyte *value, int position, int length) {
	return hl_regexp_match(expression, value, position, length);
}

HL_PRIM int HL_NAME(__regexp_matched_pos)(realtime_ereg *expression, int group) {
	return hl_regexp_matched_pos(expression, group, NULL);
}

HL_PRIM int HL_NAME(__regexp_matched_length)(realtime_ereg *expression, int group) {
	int length = 0;
	int position = hl_regexp_matched_pos(expression, group, &length);
	return position < 0 ? -1 : length;
}

HL_PRIM int HL_NAME(__regexp_matched_num)(realtime_ereg *expression) {
	return hl_regexp_matched_num(expression);
}

DEFINE_PRIM(_ABSTRACT(ereg), __regexp_new, _BYTES _BYTES);
DEFINE_PRIM(_BOOL, __regexp_match, _ABSTRACT(ereg) _BYTES _I32 _I32);
DEFINE_PRIM(_I32, __regexp_matched_pos, _ABSTRACT(ereg) _I32);
DEFINE_PRIM(_I32, __regexp_matched_length, _ABSTRACT(ereg) _I32);
DEFINE_PRIM(_I32, __regexp_matched_num, _ABSTRACT(ereg));
