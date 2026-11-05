/* Generated from compiler.ir.IrValueLaneRuntime. Do not edit. */
static void realtime_lane_reserve(varray * v0, int32_t v1);
static void realtime_lane_ensure(varray * v0, int32_t v1);
static void realtime_lane_clear_element(varray * v0, int32_t v1);
static void realtime_lane_clear_range(varray * v0, int32_t v1, int32_t v2);
static void realtime_lane_move(varray * v0, int32_t v1, varray * v2, int32_t v3, int32_t v4);
static void realtime_lane_resize(varray * v0, int32_t v1);
static int32_t realtime_lane_insert(varray * v0, int32_t v1);
static void realtime_lane_remove_at(varray * v0, int32_t v1);
static varray * realtime_lane_copy(varray * v0);
static varray * realtime_lane_slice(varray * v0, int32_t v1, int32_t v2);
static varray * realtime_lane_concat(varray * v0, varray * v1);
static varray * realtime_lane_splice(varray * v0, int32_t v1, int32_t v2);
static void realtime_lane_reverse(varray * v0);

static void realtime_lane_reserve(varray * v0, int32_t v1) {
	int32_t v2;
	bool v3;
	int32_t v4;
	bool v5;
	int32_t v6;
	int32_t v7;
	int32_t p7;
	int32_t v8;
	int32_t p8;
	bool v9;
	int32_t v10;
	int32_t v11;
	int32_t v12;
	int32_t v13;
	bool v14;
	int32_t v15;
	int32_t v16;
	int32_t p16;
	goto block_0;
block_0:
	v2 = realtime_lane_storage_capacity(v0);
	v3 = v1 <= v2;
	if (v3) { goto block_1; } else { goto block_2; }
block_1:
	return;
block_2:
	v4 = 4;
	v5 = v2 < v4;
	if (v5) { goto block_3; } else { goto block_4; }
block_3:
	v6 = 4;
	p7 = v6; v7 = p7; goto block_5;
block_4:
	p7 = v2; v7 = p7; goto block_5;
block_5:
	p8 = v7; v8 = p8; goto block_6;
block_6:
	v9 = v8 < v1;
	if (v9) { goto block_7; } else { goto block_8; }
block_7:
	v10 = 2;
	v11 = v8 / v10;
	v12 = 2147483647;
	v13 = (int32_t)((uint32_t)v12 - (uint32_t)v11);
	v14 = v13 < v8;
	if (v14) { goto block_9; } else { goto block_10; }
block_8:
	realtime_lane_storage_replace_capacity(v0, v8);
	goto block_1;
block_9:
	p16 = v1; v16 = p16; goto block_11;
block_10:
	v15 = (int32_t)((uint32_t)v8 + (uint32_t)v11);
	p16 = v15; v16 = p16; goto block_11;
block_11:
	p8 = v16; v8 = p8; goto block_6;
}

static void realtime_lane_ensure(varray * v0, int32_t v1) {
	int32_t v2;
	bool v3;
	int32_t v7;
	bool v8;
	int32_t v4;
	vdynamic * v6;
	int32_t v12;
	bool v13;
	int32_t v9;
	vdynamic * v11;
	int32_t v14;
	int32_t v15;
	goto block_0;
block_0:
	v2 = 0;
	v3 = v2 <= v1;
	if (v3) { goto block_1; } else { goto block_2; }
block_1:
	v7 = 2147483647;
	v8 = v1 < v7;
	if (v8) { goto block_3; } else { goto block_4; }
block_2:
	v4 = 0;
	realtime_lane_storage_fail(v4);
	v6 = NULL;
	hl_throw(v6); abort();
block_3:
	v12 = realtime_lane_storage_length(v0);
	v13 = v1 < v12;
	if (v13) { goto block_6; } else { goto block_5; }
block_4:
	v9 = 0;
	realtime_lane_storage_fail(v9);
	v11 = NULL;
	hl_throw(v11); abort();
block_5:
	v14 = 1;
	v15 = (int32_t)((uint32_t)v1 + (uint32_t)v14);
	realtime_lane_reserve(v0, v15);
	realtime_lane_storage_publish_length(v0, v15);
	goto block_6;
block_6:
	return;
}

static void realtime_lane_clear_element(varray * v0, int32_t v1) {
	int32_t v2;
	bool v3;
	int32_t v7;
	bool v8;
	int32_t v4;
	vdynamic * v6;
	int32_t v12;
	int32_t v9;
	vdynamic * v11;
	goto block_0;
block_0:
	v2 = 0;
	v3 = v2 <= v1;
	if (v3) { goto block_1; } else { goto block_2; }
block_1:
	v7 = realtime_lane_storage_length(v0);
	v8 = v1 < v7;
	if (v8) { goto block_3; } else { goto block_4; }
block_2:
	v4 = 0;
	realtime_lane_storage_fail(v4);
	v6 = NULL;
	hl_throw(v6); abort();
block_3:
	v12 = 1;
	realtime_lane_clear_range(v0, v1, v12);
	return;
block_4:
	v9 = 0;
	realtime_lane_storage_fail(v9);
	v11 = NULL;
	hl_throw(v11); abort();
}

static void realtime_lane_clear_range(varray * v0, int32_t v1, int32_t v2) {
	bool v5;
	int32_t v6;
	int32_t v7;
	int32_t p7;
	bool v8;
	bool v9;
	int32_t v11;
	int32_t v12;
	goto block_0;
block_0:
	realtime_lane_storage_clear_scalars(v0, v1, v2);
	realtime_lane_storage_clear_references(v0, v1, v2);
	v5 = realtime_lane_storage_has_validity(v0);
	if (v5) { goto block_1; } else { goto block_2; }
block_1:
	v6 = (int32_t)((uint32_t)v1 + (uint32_t)v2);
	p7 = v1; v7 = p7; goto block_3;
block_2:
	return;
block_3:
	v8 = v7 < v6;
	if (v8) { goto block_4; } else { goto block_5; }
block_4:
	v9 = false;
	realtime_lane_storage_write_validity(v0, v7, v9);
	v11 = 1;
	v12 = (int32_t)((uint32_t)v7 + (uint32_t)v11);
	p7 = v12; v7 = p7; goto block_3;
block_5:
	goto block_2;
}

static void realtime_lane_move(varray * v0, int32_t v1, varray * v2, int32_t v3, int32_t v4) {
	bool v7;
	bool v8;
	bool v9;
	bool v10;
	bool v11;
	bool p11;
	int32_t v12;
	int32_t v13;
	int32_t p13;
	bool v14;
	int32_t v15;
	int32_t v16;
	int32_t v17;
	int32_t v18;
	int32_t p18;
	int32_t v19;
	bool v20;
	int32_t v21;
	int32_t v23;
	int32_t v24;
	goto block_0;
block_0:
	realtime_lane_storage_copy_scalars(v0, v1, v2, v3, v4);
	realtime_lane_storage_copy_references(v0, v1, v2, v3, v4);
	v7 = realtime_lane_storage_has_validity(v2);
	if (v7) { goto block_1; } else { goto block_2; }
block_1:
	v8 = v0 == v2;
	if (v8) { goto block_3; } else { goto block_4; }
block_2:
	return;
block_3:
	v9 = v3 < v1;
	p11 = v9; v11 = p11; goto block_5;
block_4:
	v10 = false;
	p11 = v10; v11 = p11; goto block_5;
block_5:
	v12 = 0;
	p13 = v12; v13 = p13; goto block_6;
block_6:
	v14 = v13 < v4;
	if (v14) { goto block_7; } else { goto block_8; }
block_7:
	if (v11) { goto block_9; } else { goto block_10; }
block_8:
	goto block_2;
block_9:
	v15 = 1;
	v16 = (int32_t)((uint32_t)v4 - (uint32_t)v15);
	v17 = (int32_t)((uint32_t)v16 - (uint32_t)v13);
	p18 = v17; v18 = p18; goto block_11;
block_10:
	p18 = v13; v18 = p18; goto block_11;
block_11:
	v19 = (int32_t)((uint32_t)v3 + (uint32_t)v18);
	v20 = realtime_lane_storage_read_validity(v2, v19);
	v21 = (int32_t)((uint32_t)v1 + (uint32_t)v18);
	realtime_lane_storage_write_validity(v0, v21, v20);
	v23 = 1;
	v24 = (int32_t)((uint32_t)v13 + (uint32_t)v23);
	p13 = v24; v13 = p13; goto block_6;
}

static void realtime_lane_resize(varray * v0, int32_t v1) {
	int32_t v2;
	bool v3;
	int32_t v7;
	bool v8;
	int32_t v4;
	vdynamic * v6;
	int32_t v10;
	goto block_0;
block_0:
	v2 = 0;
	v3 = v2 <= v1;
	if (v3) { goto block_1; } else { goto block_2; }
block_1:
	v7 = realtime_lane_storage_length(v0);
	v8 = v7 < v1;
	if (v8) { goto block_3; } else { goto block_4; }
block_2:
	v4 = 1;
	realtime_lane_storage_fail(v4);
	v6 = NULL;
	hl_throw(v6); abort();
block_3:
	realtime_lane_reserve(v0, v1);
	goto block_5;
block_4:
	v10 = (int32_t)((uint32_t)v7 - (uint32_t)v1);
	realtime_lane_clear_range(v0, v1, v10);
	goto block_5;
block_5:
	realtime_lane_storage_publish_length(v0, v1);
	return;
}

static int32_t realtime_lane_insert(varray * v0, int32_t v1) {
	int32_t v2;
	int32_t v3;
	bool v4;
	int32_t v8;
	bool v9;
	int32_t v5;
	vdynamic * v7;
	int32_t v10;
	int32_t v11;
	int32_t p11;
	int32_t v12;
	bool v13;
	int32_t v14;
	int32_t v15;
	int32_t p15;
	bool v16;
	int32_t v17;
	int32_t p17;
	int32_t v18;
	int32_t v19;
	int32_t v22;
	int32_t v23;
	int32_t v24;
	int32_t v26;
	goto block_0;
block_0:
	v2 = realtime_lane_storage_length(v0);
	v3 = 2147483647;
	v4 = v2 < v3;
	if (v4) { goto block_1; } else { goto block_2; }
block_1:
	v8 = 0;
	v9 = v1 < v8;
	if (v9) { goto block_3; } else { goto block_4; }
block_2:
	v5 = 2;
	realtime_lane_storage_fail(v5);
	v7 = NULL;
	hl_throw(v7); abort();
block_3:
	v10 = (int32_t)((uint32_t)v1 + (uint32_t)v2);
	p11 = v10; v11 = p11; goto block_5;
block_4:
	p11 = v1; v11 = p11; goto block_5;
block_5:
	v12 = 0;
	v13 = v11 < v12;
	if (v13) { goto block_6; } else { goto block_7; }
block_6:
	v14 = 0;
	p15 = v14; v15 = p15; goto block_8;
block_7:
	p15 = v11; v15 = p15; goto block_8;
block_8:
	v16 = v2 < v15;
	if (v16) { goto block_9; } else { goto block_10; }
block_9:
	p17 = v2; v17 = p17; goto block_11;
block_10:
	p17 = v15; v17 = p17; goto block_11;
block_11:
	v18 = 1;
	v19 = (int32_t)((uint32_t)v2 + (uint32_t)v18);
	realtime_lane_reserve(v0, v19);
	realtime_lane_storage_publish_length(v0, v19);
	v22 = 1;
	v23 = (int32_t)((uint32_t)v17 + (uint32_t)v22);
	v24 = (int32_t)((uint32_t)v2 - (uint32_t)v17);
	realtime_lane_move(v0, v23, v0, v17, v24);
	v26 = 1;
	realtime_lane_clear_range(v0, v17, v26);
	return v17;
}

static void realtime_lane_remove_at(varray * v0, int32_t v1) {
	int32_t v2;
	int32_t v3;
	bool v4;
	bool v8;
	int32_t v5;
	vdynamic * v7;
	int32_t v12;
	int32_t v13;
	int32_t v14;
	int32_t v16;
	int32_t v17;
	int32_t v9;
	vdynamic * v11;
	goto block_0;
block_0:
	v2 = realtime_lane_storage_length(v0);
	v3 = 0;
	v4 = v3 <= v1;
	if (v4) { goto block_1; } else { goto block_2; }
block_1:
	v8 = v1 < v2;
	if (v8) { goto block_3; } else { goto block_4; }
block_2:
	v5 = 0;
	realtime_lane_storage_fail(v5);
	v7 = NULL;
	hl_throw(v7); abort();
block_3:
	v12 = 1;
	v13 = (int32_t)((uint32_t)v1 + (uint32_t)v12);
	v14 = (int32_t)((uint32_t)v2 - (uint32_t)v13);
	realtime_lane_move(v0, v1, v0, v13, v14);
	v16 = 1;
	v17 = (int32_t)((uint32_t)v2 - (uint32_t)v16);
	realtime_lane_resize(v0, v17);
	return;
block_4:
	v9 = 0;
	realtime_lane_storage_fail(v9);
	v11 = NULL;
	hl_throw(v11); abort();
}

static varray * realtime_lane_copy(varray * v0) {
	int32_t v1;
	varray * v2;
	int32_t v3;
	int32_t v4;
	goto block_0;
block_0:
	v1 = realtime_lane_storage_length(v0);
	v2 = realtime_lane_storage_new_like(v0, v1);
	v3 = 0;
	v4 = 0;
	realtime_lane_move(v2, v3, v0, v4, v1);
	return v2;
}

static varray * realtime_lane_slice(varray * v0, int32_t v1, int32_t v2) {
	int32_t v3;
	int32_t v4;
	bool v5;
	int32_t v6;
	int32_t v7;
	int32_t p7;
	int32_t v8;
	bool v9;
	int32_t v10;
	int32_t v11;
	int32_t p11;
	bool v12;
	int32_t v13;
	int32_t p13;
	int32_t v14;
	bool v15;
	int32_t v16;
	int32_t v17;
	int32_t p17;
	int32_t v18;
	bool v19;
	int32_t v20;
	int32_t v21;
	int32_t p21;
	bool v22;
	int32_t v23;
	int32_t p23;
	bool v24;
	int32_t v25;
	int32_t p25;
	int32_t v26;
	varray * v27;
	int32_t v28;
	goto block_0;
block_0:
	v3 = realtime_lane_storage_length(v0);
	v4 = 0;
	v5 = v1 < v4;
	if (v5) { goto block_1; } else { goto block_2; }
block_1:
	v6 = (int32_t)((uint32_t)v1 + (uint32_t)v3);
	p7 = v6; v7 = p7; goto block_3;
block_2:
	p7 = v1; v7 = p7; goto block_3;
block_3:
	v8 = 0;
	v9 = v7 < v8;
	if (v9) { goto block_4; } else { goto block_5; }
block_4:
	v10 = 0;
	p11 = v10; v11 = p11; goto block_6;
block_5:
	p11 = v7; v11 = p11; goto block_6;
block_6:
	v12 = v3 < v11;
	if (v12) { goto block_7; } else { goto block_8; }
block_7:
	p13 = v3; v13 = p13; goto block_9;
block_8:
	p13 = v11; v13 = p13; goto block_9;
block_9:
	v14 = 0;
	v15 = v2 < v14;
	if (v15) { goto block_10; } else { goto block_11; }
block_10:
	v16 = (int32_t)((uint32_t)v2 + (uint32_t)v3);
	p17 = v16; v17 = p17; goto block_12;
block_11:
	p17 = v2; v17 = p17; goto block_12;
block_12:
	v18 = 0;
	v19 = v17 < v18;
	if (v19) { goto block_13; } else { goto block_14; }
block_13:
	v20 = 0;
	p21 = v20; v21 = p21; goto block_15;
block_14:
	p21 = v17; v21 = p21; goto block_15;
block_15:
	v22 = v3 < v21;
	if (v22) { goto block_16; } else { goto block_17; }
block_16:
	p23 = v3; v23 = p23; goto block_18;
block_17:
	p23 = v21; v23 = p23; goto block_18;
block_18:
	v24 = v23 < v13;
	if (v24) { goto block_19; } else { goto block_20; }
block_19:
	p25 = v13; v25 = p25; goto block_21;
block_20:
	p25 = v23; v25 = p25; goto block_21;
block_21:
	v26 = (int32_t)((uint32_t)v25 - (uint32_t)v13);
	v27 = realtime_lane_storage_new_like(v0, v26);
	v28 = 0;
	realtime_lane_move(v27, v28, v0, v13, v26);
	return v27;
}

static varray * realtime_lane_concat(varray * v0, varray * v1) {
	bool v2;
	int32_t v6;
	int32_t v7;
	int32_t v8;
	int32_t v9;
	bool v10;
	int32_t v3;
	vdynamic * v5;
	int32_t v14;
	varray * v15;
	int32_t v16;
	int32_t v17;
	int32_t v19;
	int32_t v11;
	vdynamic * v13;
	goto block_0;
block_0:
	v2 = realtime_lane_storage_compatible(v0, v1);
	if (v2) { goto block_1; } else { goto block_2; }
block_1:
	v6 = realtime_lane_storage_length(v0);
	v7 = realtime_lane_storage_length(v1);
	v8 = 2147483647;
	v9 = (int32_t)((uint32_t)v8 - (uint32_t)v6);
	v10 = v7 <= v9;
	if (v10) { goto block_3; } else { goto block_4; }
block_2:
	v3 = 3;
	realtime_lane_storage_fail(v3);
	v5 = NULL;
	hl_throw(v5); abort();
block_3:
	v14 = (int32_t)((uint32_t)v6 + (uint32_t)v7);
	v15 = realtime_lane_storage_new_like(v0, v14);
	v16 = 0;
	v17 = 0;
	realtime_lane_move(v15, v16, v0, v17, v6);
	v19 = 0;
	realtime_lane_move(v15, v6, v1, v19, v7);
	return v15;
block_4:
	v11 = 2;
	realtime_lane_storage_fail(v11);
	v13 = NULL;
	hl_throw(v13); abort();
}

static varray * realtime_lane_splice(varray * v0, int32_t v1, int32_t v2) {
	int32_t v3;
	int32_t v4;
	bool v5;
	int32_t v7;
	varray * v8;
	bool v6;
	int32_t v9;
	bool v10;
	int32_t v11;
	int32_t v12;
	int32_t p12;
	int32_t v13;
	bool v14;
	int32_t v15;
	int32_t v16;
	int32_t p16;
	int32_t v17;
	bool v18;
	int32_t v19;
	int32_t p19;
	varray * v20;
	int32_t v21;
	int32_t v22;
	int32_t v24;
	int32_t v26;
	goto block_0;
block_0:
	v3 = realtime_lane_storage_length(v0);
	v4 = 0;
	v5 = v2 < v4;
	if (v5) { goto block_1; } else { goto block_2; }
block_1:
	v7 = 0;
	v8 = realtime_lane_storage_new_like(v0, v7);
	return v8;
block_2:
	v6 = v3 < v1;
	if (v6) { goto block_1; } else { goto block_3; }
block_3:
	v9 = 0;
	v10 = v1 < v9;
	if (v10) { goto block_4; } else { goto block_5; }
block_4:
	v11 = (int32_t)((uint32_t)v1 + (uint32_t)v3);
	p12 = v11; v12 = p12; goto block_6;
block_5:
	p12 = v1; v12 = p12; goto block_6;
block_6:
	v13 = 0;
	v14 = v12 < v13;
	if (v14) { goto block_7; } else { goto block_8; }
block_7:
	v15 = 0;
	p16 = v15; v16 = p16; goto block_9;
block_8:
	p16 = v12; v16 = p16; goto block_9;
block_9:
	v17 = (int32_t)((uint32_t)v3 - (uint32_t)v16);
	v18 = v17 < v2;
	if (v18) { goto block_10; } else { goto block_11; }
block_10:
	p19 = v17; v19 = p19; goto block_12;
block_11:
	p19 = v2; v19 = p19; goto block_12;
block_12:
	v20 = realtime_lane_storage_new_like(v0, v19);
	v21 = (int32_t)((uint32_t)v16 + (uint32_t)v19);
	v22 = 0;
	realtime_lane_move(v20, v22, v0, v16, v19);
	v24 = (int32_t)((uint32_t)v3 - (uint32_t)v21);
	realtime_lane_move(v0, v16, v0, v21, v24);
	v26 = (int32_t)((uint32_t)v3 - (uint32_t)v19);
	realtime_lane_resize(v0, v26);
	return v20;
}

static void realtime_lane_reverse(varray * v0) {
	int32_t v1;
	int32_t v2;
	int32_t v3;
	int32_t v4;
	int32_t v5;
	int32_t p5;
	bool v6;
	int32_t v7;
	int32_t v8;
	int32_t v9;
	bool v10;
	bool v11;
	int32_t v16;
	int32_t v17;
	goto block_0;
block_0:
	v1 = realtime_lane_storage_length(v0);
	v2 = 0;
	v3 = 2;
	v4 = v1 / v3;
	p5 = v2; v5 = p5; goto block_1;
block_1:
	v6 = v5 < v4;
	if (v6) { goto block_2; } else { goto block_3; }
block_2:
	v7 = 1;
	v8 = (int32_t)((uint32_t)v1 - (uint32_t)v7);
	v9 = (int32_t)((uint32_t)v8 - (uint32_t)v5);
	v10 = realtime_lane_storage_read_validity(v0, v5);
	v11 = realtime_lane_storage_read_validity(v0, v9);
	realtime_lane_storage_swap_scalars(v0, v5, v9);
	realtime_lane_storage_swap_references(v0, v5, v9);
	realtime_lane_storage_write_validity(v0, v5, v11);
	realtime_lane_storage_write_validity(v0, v9, v10);
	v16 = 1;
	v17 = (int32_t)((uint32_t)v5 + (uint32_t)v16);
	p5 = v17; v5 = p5; goto block_1;
block_3:
	return;
}
