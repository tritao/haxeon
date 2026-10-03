typedef struct realtime_iterator {
	varray *values;
	int position;
} realtime_iterator;

extern vdynamic *hl_make_dyn(void *data, hl_type *type);

// MEM_KIND_RAW blocks are scanned by the collector, so the iterator keeps its array alive without a GC root or
// a finalizer. Rooting every iterator serialized on the collector's global lock and made iterating cost far more
// than the loop it drives.
HL_PRIM realtime_iterator *HL_NAME(__iterator_new)(vdynamic *value) {
	if (value == NULL || value->t->kind != HARRAY)
		hl_error("Iterator source must be an Array");
	realtime_iterator *iterator = (realtime_iterator *)hl_gc_alloc_raw(sizeof(realtime_iterator));
	iterator->values = (varray *)value;
	iterator->position = 0;
	return iterator;
}

HL_PRIM bool HL_NAME(__iterator_has_next)(realtime_iterator *iterator) {
	return iterator != NULL && iterator->values != NULL && iterator->position < iterator->values->size;
}

HL_PRIM vdynamic *HL_NAME(__iterator_next)(realtime_iterator *iterator) {
	if (!HL_NAME(__iterator_has_next)(iterator))
		hl_error("Iterator has no next value");
	hl_type *type = iterator->values->at;
	void *source = hl_aptr(iterator->values, vbyte) + (size_t)iterator->position++ * (size_t)hl_type_size(type);
	return hl_make_dyn(source, type);
}

// Typed variants for the Float and Int element reads the compiler selects: reading the element in place avoids
// boxing it into a Dynamic and casting it back on every step. Arrays of another scalar width are converted with
// HashLink's own cast, which also needs no allocation.
HL_PRIM double HL_NAME(__iterator_next_f64)(realtime_iterator *iterator) {
	if (!HL_NAME(__iterator_has_next)(iterator))
		hl_error("Iterator has no next value");
	hl_type *type = iterator->values->at;
	if (type->kind == HF64)
		return hl_aptr(iterator->values, double)[iterator->position++];
	void *source = hl_aptr(iterator->values, vbyte) + (size_t)iterator->position++ * (size_t)hl_type_size(type);
	return hl_dyn_castd(source, type);
}

HL_PRIM int HL_NAME(__iterator_next_i32)(realtime_iterator *iterator) {
	if (!HL_NAME(__iterator_has_next)(iterator))
		hl_error("Iterator has no next value");
	hl_type *type = iterator->values->at;
	if (type->kind == HI32)
		return hl_aptr(iterator->values, int)[iterator->position++];
	void *source = hl_aptr(iterator->values, vbyte) + (size_t)iterator->position++ * (size_t)hl_type_size(type);
	return hl_dyn_casti(source, type, &hlt_i32);
}
