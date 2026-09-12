typedef struct realtime_process_output {
	vbyte *data;
	int length;
	int capacity;
} realtime_process_output;

extern void *hl_process_run(vbyte *command, varray *arguments, bool detached);
extern int hl_process_stdout_read(void *process, vbyte *bytes, int position, int length);
extern int hl_process_stderr_read(void *process, vbyte *bytes, int position, int length);
extern int hl_process_exit(void *process, bool *running);
extern void hl_process_close(void *process);
extern void hl_process_kill(void *process);

static vbyte *realtime_process_read(void *process, bool stdout_stream) {
	realtime_process_output output = {NULL, 0, 0};
	for (;;) {
		if (output.capacity - output.length < 16384) {
			int capacity = output.capacity == 0 ? 16384 : output.capacity * 2;
			vbyte *data = (vbyte *)realloc(output.data, (size_t)capacity);
			if (data == NULL) {
				free(output.data);
				hl_error("Could not grow process output");
			}
			output.data = data;
			output.capacity = capacity;
		}
		int read = stdout_stream
			? hl_process_stdout_read(process, output.data, output.length, output.capacity - output.length)
			: hl_process_stderr_read(process, output.data, output.length, output.capacity - output.length);
		if (read < 0)
			break;
		if (read == 0) {
			free(output.data);
			hl_error("Process output read was blocked");
		}
		output.length += read;
	}
	if (output.data == NULL)
		return realtime_string_from_utf8("");
	output.data = (vbyte *)realloc(output.data, (size_t)output.length + 1);
	output.data[output.length] = 0;
	vbyte *result = realtime_string_from_utf8((const char *)output.data);
	free(output.data);
	return result;
}

HL_PRIM void *HL_NAME(__process_run)(vbyte *command, varray *arguments) {
	if (command == NULL || ((const uchar *)command)[0] == 0)
		hl_error("Process command cannot be empty");
#ifdef HL_WIN
	if (arguments != NULL && arguments->size != 0)
		hl_error("Process arguments are not yet supported on Windows");
	void *process = hl_process_run(command, NULL, false);
#else
	char *command_utf8 = realtime_utf8_copy(command);
	varray *native_arguments = hl_alloc_array(&hlt_bytes, arguments == NULL ? 0 : arguments->size);
	vbyte **native_values = hl_aptr(native_arguments, vbyte *);
	for (int index = 0; index < native_arguments->size; index++) {
		vbyte *argument = hl_aptr(arguments, vbyte *)[index];
		native_values[index] = (vbyte *)realtime_utf8_copy(argument);
	}
	void *process = hl_process_run((vbyte *)command_utf8, native_arguments, false);
	for (int index = 0; index < native_arguments->size; index++)
		free(native_values[index]);
	free(command_utf8);
#endif
	if (process == NULL)
		hl_error("Could not start process");
	return process;
}

HL_PRIM vbyte *HL_NAME(__process_read_stdout)(void *process) { return realtime_process_read(process, true); }
HL_PRIM vbyte *HL_NAME(__process_read_stderr)(void *process) { return realtime_process_read(process, false); }
HL_PRIM int HL_NAME(__process_exit)(void *process) { return hl_process_exit(process, NULL); }
HL_PRIM void HL_NAME(__process_close)(void *process) { hl_process_close(process); }
HL_PRIM void HL_NAME(__process_kill)(void *process) { hl_process_kill(process); }
