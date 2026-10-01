extern vdynamic *hl_obj_get_field(vdynamic *object, int field);
extern bool hl_obj_has_field(vdynamic *object, int field);
extern bool hl_obj_delete_field(vdynamic *object, int field);
extern varray *hl_obj_fields(vdynamic *object);

extern vdynamic *hl_obj_copy(vdynamic *object);

HL_PRIM vdynamic *HL_NAME(__reflect_copy)(vdynamic *object) {
	if (!object) return NULL;
	if (object->t->kind == HVIRTUAL && ((vvirtual *)object)->value)
		return HL_NAME(__reflect_copy)(((vvirtual *)object)->value);
	if (object->t->kind != HOBJ) return hl_obj_copy(object);

	vdynamic *copy = (vdynamic *)hl_alloc_obj(object->t);
	for (hl_type *type = object->t; type; type = type->obj->super) {
		for (int index = 0; index < type->obj->nfields; index++) {
			hl_runtime_obj *layout = type->obj->rt;
			bool cached_interface = false;
			for (int slot = 0; slot < layout->ninterfaces; slot++)
				if (layout->interfaces[slot] == index) cached_interface = true;
			if (cached_interface) continue;
			hl_obj_field *field = &type->obj->fields[index];
			int name = field->hashed_name;
			hl_type *value_type = field->t;
			switch (value_type->kind) {
			case HUI8:
			case HUI16:
			case HI32:
			case HBOOL:
				hl_dyn_seti(copy, name, value_type, hl_dyn_geti(object, name, value_type));
				break;
			case HI64:
				hl_dyn_seti64(copy, name, hl_dyn_geti64(object, name));
				break;
			case HF32:
				hl_dyn_setf(copy, name, hl_dyn_getf(object, name));
				break;
			case HF64:
				hl_dyn_setd(copy, name, hl_dyn_getd(object, name));
				break;
			default:
				hl_dyn_setp(copy, name, value_type, hl_dyn_getp(object, name, value_type));
				break;
			}
		}
	}
	return copy;
}

HL_PRIM vdynamic *HL_NAME(__reflect_field)(vdynamic *object, vstring *name) {
	return name ? hl_obj_get_field(object, hl_hash((vbyte *)name->bytes)) : NULL;
}

HL_PRIM void HL_NAME(__reflect_set_field)(vdynamic *object, vstring *name,
		vdynamic *value) {
	if (!name) hl_error("Null field name");
	int field = hl_hash((vbyte *)name->bytes);
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

HL_PRIM bool HL_NAME(__reflect_has_field)(vdynamic *object, vstring *name) {
	return name && hl_obj_has_field(object, hl_hash((vbyte *)name->bytes));
}

HL_PRIM bool HL_NAME(__reflect_delete_field)(vdynamic *object, vstring *name) {
	return name && hl_obj_delete_field(object, hl_hash((vbyte *)name->bytes));
}

HL_PRIM int HL_NAME(__reflect_field_count)(vdynamic *object) {
	varray *fields = hl_obj_fields(object);
	return fields ? fields->size : 0;
}

HL_PRIM vstring *HL_NAME(__reflect_field_name)(vdynamic *object, int index) {
	varray *fields = hl_obj_fields(object);
	if (!fields || index < 0 || index >= fields->size) return NULL;
	uchar *name = hl_aptr(fields, uchar *)[index];
	return name == NULL ? NULL : realtime_string_wrap(name, (int)ustrlen(name));
}

HL_PRIM vdynamic *HL_NAME(__reflect_dynamic_object)(void) {
	return (vdynamic *)hl_alloc_dynobj();
}

HL_PRIM bool HL_NAME(__reflect_is_function)(vdynamic *value) {
	return value && (value->t->kind == HFUN || value->t->kind == HMETHOD);
}

HL_PRIM bool HL_NAME(__reflect_is_object)(vdynamic *value) {
	if (!value || realtime_is_string(value)) return false;
	switch (value->t->kind) {
	case HOBJ:
	case HARRAY:
	case HTYPE:
	case HVIRTUAL:
	case HDYNOBJ:
	case HENUM:
	case HSTRUCT:
		return true;
	default:
		return false;
	}
}

HL_PRIM vdynamic *HL_NAME(__reflect_array_get)(vdynamic *value, int index) {
	if (!value || value->t->kind != HARRAY) hl_error("Value is not an array");
	varray *array = (varray *)value;
	hl_array_check(array, index);
	return hl_make_dyn(hl_aptr(array, vbyte) + index * hl_type_size(array->at),
		array->at);
}

HL_PRIM int HL_NAME(__reflect_array_length)(vdynamic *value) {
	if (!value || value->t->kind != HARRAY) hl_error("Value is not an array");
	return ((varray *)value)->size;
}

HL_PRIM int HL_NAME(__json_value_kind)(vdynamic *value) {
	if (!value) return 0;
	if (realtime_is_string(value)) return 1;
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
