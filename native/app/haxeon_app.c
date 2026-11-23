/* The platform's entry points of an app's executable, and of any program Haxeon compiles ahead of time
 * (docs/design/PROJECT_BUILDS.md, desktop runner). Each only calls haxeon_app_run, which a flavour of the program defines
 * once: the JIT VM that loads the app's module (libhaxeon-app, native/app/haxeon_app_main.c), or the program compiled ahead of
 * time (native/aot/hlc_main.c). Entries of other platforms (Android's JNI start, the web loader's export) call it the same way.
 *
 * On Windows both wmain and wWinMain are here, and the linker starts the one of the executable's subsystem: apps are Windows
 * programs (haxeon_add_app sets WIN32_EXECUTABLE), which open no console window from Explorer; programs that are not apps
 * are console programs. */
#ifdef _WIN32
#	include <windows.h>
#	include <stdio.h>
#	include <stdlib.h>
#	include <io.h>

int haxeon_app_run( int argc, wchar_t *argv[] );

int wmain( int argc, wchar_t *argv[] ) { return haxeon_app_run(argc,argv); }

static int usable_handle( DWORD which ) {
	HANDLE handle = GetStdHandle(which);
	return handle != NULL && handle != INVALID_HANDLE_VALUE && GetFileType(handle) != FILE_TYPE_UNKNOWN;
}

static void open_on_console( FILE *stream, DWORD which ) {
	FILE *reopened;
	if( freopen_s(&reopened,"CONOUT$","w",stream) == 0 )
		SetStdHandle(which,(HANDLE)_get_osfhandle(_fileno(stream)));
}

/* A Windows program started from a terminal has no standard output or error of its own, so what it prints, its traces and
 * errors among them, would be lost: the streams without a handle go to the terminal's console, or under a debugger to a
 * console of the program's own. Streams that have one, such as the pipes `haxeon run` and the tests give the app, stay. */
int WINAPI wWinMain( HINSTANCE instance, HINSTANCE previous, PWSTR command_line, int show ) {
	int output = usable_handle(STD_OUTPUT_HANDLE), error = usable_handle(STD_ERROR_HANDLE);
	(void)instance; (void)previous; (void)command_line; (void)show;
	if( !(output && error) && (AttachConsole(ATTACH_PARENT_PROCESS) || (IsDebuggerPresent() && AllocConsole())) ) {
		if( !output ) open_on_console(stdout,STD_OUTPUT_HANDLE);
		if( !error ) open_on_console(stderr,STD_ERROR_HANDLE);
	}
	return haxeon_app_run(__argc,__wargv);
}
#else
int haxeon_app_run( int argc, char *argv[] );

int main( int argc, char *argv[] ) { return haxeon_app_run(argc,argv); }
#endif
