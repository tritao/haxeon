HL_PRIM void HL_NAME(__file_save_bytes)( vbyte *path, realtime_bytes *bytes ) {
	FILE *file = fopen(hl_to_utf8((const uchar *)path), "wb");
	if( file == NULL ) hl_error("Could not open output file");
	if( bytes->length > 0 && fwrite(bytes->data, 1, (size_t)bytes->length, file) != (size_t)bytes->length ) {
		fclose(file);
		hl_error("Could not write output file");
	}
	if( fclose(file) != 0 ) hl_error("Could not close output file");
}

HL_PRIM void HL_NAME(__file_save_content)( vbyte *path, vbyte *content ) {
	const char *path_utf8 = hl_to_utf8((const uchar *)path);
	char *owned_path = (char *)malloc(strlen(path_utf8) + 1);
	if( owned_path == NULL ) hl_error("Could not allocate output path");
	strcpy(owned_path, path_utf8);
	const char *utf8 = content == NULL ? "" : hl_to_utf8((const uchar *)content);
	FILE *file = fopen(owned_path, "wb");
	free(owned_path);
	if( file == NULL ) hl_error("Could not open output file");
	size_t length = strlen(utf8);
	if( length > 0 && fwrite(utf8, 1, length, file) != length ) {
		fclose(file);
		hl_error("Could not write output file");
	}
	if( fclose(file) != 0 ) hl_error("Could not close output file");
}


HL_PRIM vbyte *HL_NAME(__file_get_content)( vbyte *path ) {
	FILE *file = fopen(hl_to_utf8((const uchar *)path), "rb");
	if( file == NULL ) hl_error("Could not open source file");
	if( fseek(file, 0, SEEK_END) != 0 ) {
		fclose(file);
		hl_error("Could not seek source file");
	}
	long byte_length = ftell(file);
	if( byte_length < 0 || fseek(file, 0, SEEK_SET) != 0 ) {
		fclose(file);
		hl_error("Could not measure source file");
	}
	char *utf8 = (char *)malloc((size_t)byte_length + 1);
	if( utf8 == NULL ) {
		fclose(file);
		hl_error("Could not allocate source buffer");
	}
	if( fread(utf8, 1, (size_t)byte_length, file) != (size_t)byte_length ) {
		free(utf8);
		fclose(file);
		hl_error("Could not read source file");
	}
	fclose(file);
	utf8[byte_length] = 0;
	int length = hl_utf8_length((vbyte *)utf8, 0);
	uchar *result = (uchar *)hl_alloc_bytes((length + 1) * (int)sizeof(uchar));
	hl_from_utf8(result, length, utf8);
	result[length] = 0;
	free(utf8);
	return (vbyte *)result;
}
