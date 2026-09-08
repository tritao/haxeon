extern vdynamic *hl_obj_get_field(vdynamic *object, int field);
extern bool hl_obj_has_field(vdynamic *object, int field);
extern varray *hl_obj_fields(vdynamic *object);

HL_PRIM vdynamic *HL_NAME(__reflect_field)(vdynamic *object, vbyte *name) {
	return name ? hl_obj_get_field(object, hl_hash(name)) : NULL;
}

HL_PRIM void HL_NAME(__reflect_set_field)(vdynamic *object, vbyte *name,
		vdynamic *value) {
	if (!name) hl_error("Null field name");
	int field = hl_hash(name);
	if (!value) {
		hl_dyn_setp(object, field, &hlt_dyn, NULL);
		return;
	}
	switch (value->t->kind) {
	case HUI8:
	case HUI16:
	case HI32:
	case HBOOL: hl_dyn_seti(object, field, value->t, value->v.i); break;
	case HI64: hl_dyn_seti64(object, field, value->v.i64); break;
	case HF32: hl_dyn_setf(object, field, value->v.f); break;
	case HF64: hl_dyn_setd(object, field, value->v.d); break;
	case HBYTES:
	case HTYPE:
	case HREF:
	case HABSTRACT: hl_dyn_setp(object, field, value->t, value->v.ptr); break;
	default: hl_dyn_setp(object, field, value->t, value); break;
	}
}

HL_PRIM bool HL_NAME(__reflect_has_field)(vdynamic *object, vbyte *name) {
	return name && hl_obj_has_field(object, hl_hash(name));
}

HL_PRIM int HL_NAME(__reflect_field_count)(vdynamic *object) {
	varray *fields = hl_obj_fields(object);
	return fields ? fields->size : 0;
}

HL_PRIM vbyte *HL_NAME(__reflect_field_name)(vdynamic *object, int index) {
	varray *fields = hl_obj_fields(object);
	if (!fields || index < 0 || index >= fields->size) return NULL;
	return hl_aptr(fields, vbyte *)[index];
}

HL_PRIM vdynamic *HL_NAME(__reflect_dynamic_object)(void) {
	return (vdynamic *)hl_alloc_dynobj();
}

HL_PRIM bool HL_NAME(__reflect_is_function)(vdynamic *value) {
	return value && (value->t->kind == HFUN || value->t->kind == HMETHOD);
}

HL_PRIM vdynamic *HL_NAME(__reflect_array_get)(vdynamic *value, int index) {
	if (!value || value->t->kind != HARRAY) hl_error("Value is not an array");
	varray *array = (varray *)value;
	hl_array_check(array, index);
	return hl_make_dyn(hl_aptr(array, vbyte) + index * hl_type_size(array->at),
		array->at);
}

HL_PRIM int HL_NAME(__json_value_kind)(vdynamic *value) {
	if (!value) return 0;
	switch (value->t->kind) {
	case HBYTES: return 1;
	case HBOOL: return 2;
	case HUI8:
	case HUI16:
	case HI32:
	case HI64: return 3;
	case HF32:
	case HF64: return 4;
	case HARRAY: return 5;
	case HFUN:
	case HMETHOD: return 6;
	default: return 7;
	}
}
