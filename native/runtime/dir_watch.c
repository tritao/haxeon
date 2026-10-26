/* Directory change notifications for the host watch loop (`haxeon run --watch`). A wait reports that something under a
   watched directory changed, not what: the caller compares its own snapshot, so a missed or coarse event costs only a
   scan. Windows uses ReadDirectoryChangesW; elsewhere open returns null and the caller polls. */
#define DIR_WATCH_MAX 64

#ifdef HL_WIN
typedef struct {
	HANDLE directory;
	HANDLE event;
	OVERLAPPED overlapped;
	BOOL recursive;
	DWORD buffer[4096];
} realtime_dir_watch_entry;

typedef struct {
	int count;
	realtime_dir_watch_entry *entries[DIR_WATCH_MAX];
} realtime_dir_watch;

static BOOL realtime_dir_watch_issue(realtime_dir_watch_entry *entry) {
	ResetEvent(entry->event);
	memset(&entry->overlapped, 0, sizeof(entry->overlapped));
	entry->overlapped.hEvent = entry->event;
	return ReadDirectoryChangesW(entry->directory, entry->buffer, sizeof(entry->buffer), entry->recursive,
		FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_SIZE | FILE_NOTIFY_CHANGE_LAST_WRITE |
			FILE_NOTIFY_CHANGE_CREATION,
		NULL, &entry->overlapped, NULL);
}
#endif

HL_PRIM void *HL_NAME(__dir_watch_open)(void) {
#ifdef HL_WIN
	return calloc(1, sizeof(realtime_dir_watch));
#else
	return NULL;
#endif
}

/* Watches a UTF-8 directory path; false when it cannot be watched. */
HL_PRIM bool HL_NAME(__dir_watch_add)(void *handle, vbyte *path, bool recursive) {
#ifdef HL_WIN
	realtime_dir_watch *watch = (realtime_dir_watch *)handle;
	if (watch == NULL || path == NULL || watch->count >= DIR_WATCH_MAX) return false;
	int length = MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, NULL, 0);
	if (length <= 0) return false;
	WCHAR *wide = (WCHAR *)malloc(sizeof(WCHAR) * (size_t)length);
	if (wide == NULL) return false;
	MultiByteToWideChar(CP_UTF8, 0, (const char *)path, -1, wide, length);
	HANDLE directory = CreateFileW(wide, FILE_LIST_DIRECTORY, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
		OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED, NULL);
	free(wide);
	if (directory == INVALID_HANDLE_VALUE) return false;
	realtime_dir_watch_entry *entry = (realtime_dir_watch_entry *)calloc(1, sizeof(realtime_dir_watch_entry));
	if (entry == NULL) {
		CloseHandle(directory);
		return false;
	}
	entry->directory = directory;
	entry->recursive = recursive ? TRUE : FALSE;
	entry->event = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (entry->event == NULL || !realtime_dir_watch_issue(entry)) {
		if (entry->event != NULL) CloseHandle(entry->event);
		CloseHandle(directory);
		free(entry);
		return false;
	}
	watch->entries[watch->count++] = entry;
	return true;
#else
	return false;
#endif
}

/* Waits up to `milliseconds` for a change: 0 when none, 1 when something changed, 2 when changes may have been lost
   (the buffer overflowed or a watch failed), which the caller treats as "rescan everything". */
HL_PRIM int HL_NAME(__dir_watch_wait)(void *handle, int milliseconds) {
#ifdef HL_WIN
	realtime_dir_watch *watch = (realtime_dir_watch *)handle;
	if (watch == NULL || watch->count == 0) return 2;
	HANDLE events[DIR_WATCH_MAX];
	for (int index = 0; index < watch->count; index++) events[index] = watch->entries[index]->event;
	hl_blocking(true);
	DWORD waited = WaitForMultipleObjects((DWORD)watch->count, events, FALSE, milliseconds < 0 ? INFINITE : (DWORD)milliseconds);
	hl_blocking(false);
	if (waited == WAIT_TIMEOUT) return 0;
	if (waited >= WAIT_OBJECT_0 + (DWORD)watch->count) return 2;
	int result = 1;
	/* Every signalled entry is consumed and armed again, so one wait reports all that changed since the last. */
	for (int index = 0; index < watch->count; index++) {
		realtime_dir_watch_entry *entry = watch->entries[index];
		if (WaitForSingleObject(entry->event, 0) != WAIT_OBJECT_0) continue;
		DWORD bytes = 0;
		if (!GetOverlappedResult(entry->directory, &entry->overlapped, &bytes, FALSE) || bytes == 0) result = 2;
		if (!realtime_dir_watch_issue(entry)) result = 2;
	}
	return result;
#else
	return 2;
#endif
}

HL_PRIM void HL_NAME(__dir_watch_close)(void *handle) {
#ifdef HL_WIN
	realtime_dir_watch *watch = (realtime_dir_watch *)handle;
	if (watch == NULL) return;
	for (int index = 0; index < watch->count; index++) {
		realtime_dir_watch_entry *entry = watch->entries[index];
		CancelIoEx(entry->directory, &entry->overlapped);
		/* The kernel may still write into the buffer until the cancelled request completes. */
		DWORD bytes = 0;
		GetOverlappedResult(entry->directory, &entry->overlapped, &bytes, TRUE);
		CloseHandle(entry->directory);
		CloseHandle(entry->event);
		free(entry);
	}
	free(watch);
#endif
}

DEFINE_PRIM(_BYTES,__dir_watch_open,_NO_ARG);
DEFINE_PRIM(_BOOL,__dir_watch_add,_BYTES _BYTES _BOOL);
DEFINE_PRIM(_I32,__dir_watch_wait,_BYTES _I32);
DEFINE_PRIM(_VOID,__dir_watch_close,_BYTES);
