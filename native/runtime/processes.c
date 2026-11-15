extern void *hl_process_run(vbyte *command, varray *arguments, bool detached);
extern int hl_process_stdout_read(void *process, vbyte *bytes, int position, int length);
extern int hl_process_stderr_read(void *process, vbyte *bytes, int position, int length);
extern int hl_process_stdin_write(void *process, vbyte *bytes, int position, int length);
extern bool hl_process_stdin_close(void *process);
extern int hl_process_exit(void *process, bool *running);
extern int hl_process_pid(void *process);
extern void hl_process_close(void *process);
extern void hl_process_kill(void *process);

/*
 * Starts `command` for sys.io.Process. Without `arguments` the command line goes to the shell, as in Haxe; with them the
 * command runs directly (Windows takes a command line, so sys.io.Process quotes the arguments into it there).
 */
HL_PRIM void *HL_NAME(__process_open)(vstring *command, varray *arguments, bool detached) {
	if (command == NULL || command->length == 0)
		hl_error("Process command cannot be empty");
#ifdef HL_WIN
	if (arguments != NULL)
		hl_error("Process arguments are quoted into the command line on Windows");
	void *process = hl_process_run((vbyte *)realtime_string_data(command), NULL, detached);
#else
	char *command_utf8 = realtime_utf8_copy(command);
	varray *native_arguments = NULL;
	if (arguments != NULL) {
		native_arguments = hl_alloc_array(&hlt_bytes, arguments->size);
		vbyte **native_values = hl_aptr(native_arguments, vbyte *);
		for (int index = 0; index < arguments->size; index++)
			native_values[index] = (vbyte *)realtime_utf8_copy(hl_aptr(arguments, vstring *)[index]);
	}
	void *process = hl_process_run((vbyte *)command_utf8, native_arguments, detached);
	if (native_arguments != NULL)
		for (int index = 0; index < native_arguments->size; index++)
			free(hl_aptr(native_arguments, vbyte *)[index]);
	free(command_utf8);
#endif
	if (process == NULL)
		hl_error("Could not start process");
	return process;
}

/* Reads into `bytes`: the count read, or -1 once the stream has ended. */
HL_PRIM int HL_NAME(__process_stdout_read)(void *process, realtime_bytes *bytes, int pos, int len) {
	realtime_bytes_bounds(bytes, pos, len);
	return len == 0 ? 0 : hl_process_stdout_read(process, bytes->data, pos, len);
}

HL_PRIM int HL_NAME(__process_stderr_read)(void *process, realtime_bytes *bytes, int pos, int len) {
	realtime_bytes_bounds(bytes, pos, len);
	return len == 0 ? 0 : hl_process_stderr_read(process, bytes->data, pos, len);
}

/* Writes from `bytes`: the count written, or -1 when the child no longer reads. */
HL_PRIM int HL_NAME(__process_stdin_write)(void *process, realtime_bytes *bytes, int pos, int len) {
	realtime_bytes_bounds(bytes, pos, len);
	return len == 0 ? 0 : hl_process_stdin_write(process, bytes->data, pos, len);
}

HL_PRIM bool HL_NAME(__process_stdin_close)(void *process) { return hl_process_stdin_close(process); }

/* The exit code; without `block`, INT_MIN while the child still runs. */
HL_PRIM int HL_NAME(__process_exit)(void *process, bool block) {
	if (block)
		return hl_process_exit(process, NULL);
	bool running = false;
	int code = hl_process_exit(process, &running);
	return running ? INT_MIN : code;
}

HL_PRIM int HL_NAME(__process_pid)(void *process) { return hl_process_pid(process); }
HL_PRIM void HL_NAME(__process_close)(void *process) { hl_process_close(process); }
HL_PRIM void HL_NAME(__process_kill)(void *process) { hl_process_kill(process); }
