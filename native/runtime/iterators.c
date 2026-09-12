typedef struct realtime_iterator {
	void (*finalize)(void *);
	varray *values;
	int position;
} realtime_iterator;

extern vdynamic *hl_make_dyn(void *data, hl_type *type);

static void realtime_iterator_finalize(void *value) {
	realtime_iterator *iterator = (realtime_iterator *)value;
	if (iterator->values != NULL)
		hl_remove_root(&iterator->values);
	iterator->values = NULL;
}

HL_PRIM realtime_iterator *HL_NAME(__iterator_new)(vdynamic *value) {
	if (value == NULL || value->t->kind != HARRAY)
		hl_error("Iterator source must be an Array");
	realtime_iterator *iterator = (realtime_iterator *)hl_gc_alloc_finalizer(sizeof(realtime_iterator));
	iterator->finalize = realtime_iterator_finalize;
	iterator->values = (varray *)value;
	iterator->position = 0;
	hl_add_root(&iterator->values);
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
