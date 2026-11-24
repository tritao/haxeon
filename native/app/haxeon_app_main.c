/* An app's development build (docs/design/PROJECT_BUILDS.md): haxeon_app_run, which the SDK's entry points (haxeon_app.c)
 * call, starts the HashLink VM on the app's module, which sits
 * beside the executable under its name (`hello-app` runs `hello-app.hl`), or in a macOS bundle among its resources
 * (`hello-app.app/Contents/MacOS/hello-app` runs `hello-app.app/Contents/Resources/hello-app.hl`). `--vm-debug-port=PORT` as
 * the first argument makes the VM wait for a debugger on PORT. `--haxeon-module=PATH` as the first argument, or immediately
 * after `--vm-debug-port=PORT`, runs PATH instead: `haxeon run --watch` runs the module it rebuilds so, or, patching, the live host,
 * which takes the app's module as an argument, in the app's own executable. Every other argument is the program's (Sys.args()).
 *
 * An app's executable compiles only the entry points, nothing of HashLink's: the VM, its entry point and this file are
 * libhaxeon-app, built by Haxeon's native build with HashLink's flags. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MODULE_OPTION "--haxeon-module="
#define DEBUG_OPTION "--vm-debug-port="

#ifdef _WIN32
#	include <windows.h>
#	include <wchar.h>

int hl_vm_main( int argc, wchar_t *argv[] );

int haxeon_app_run( int argc, wchar_t *argv[] ) {
	DWORD capacity = 32768, length;
	wchar_t *path = (wchar_t*)malloc(sizeof(wchar_t) * (capacity + 4)), *dot, *slash;
	wchar_t **arguments = (wchar_t**)malloc(sizeof(wchar_t*) * ((size_t)argc + 4));
	int count = 0, first = 1;
	if( path == NULL || arguments == NULL ) return 70;
	length = GetModuleFileNameW(NULL,path,capacity);
	if( length == 0 || length >= capacity ) { fprintf(stderr,"haxeon app: cannot find its own executable\n"); return 70; }
	/* app.exe runs app.hl */
	dot = wcsrchr(path,L'.');
	slash = wcsrchr(path,L'\\');
	if( dot != NULL && (slash == NULL || dot > slash) ) *dot = 0;
	wcscat(path,L".hl");
	arguments[count++] = argv[0];
	if( first < argc && wcsncmp(argv[first],L"" DEBUG_OPTION,wcslen(L"" DEBUG_OPTION)) == 0 ) {
		arguments[count++] = L"--debug-wait";
		arguments[count++] = L"--debug";
		arguments[count++] = argv[first++] + wcslen(L"" DEBUG_OPTION);
	}
	if( first < argc && wcsncmp(argv[first],L"" MODULE_OPTION,wcslen(L"" MODULE_OPTION)) == 0 )
		path = argv[first++] + wcslen(L"" MODULE_OPTION);
	arguments[count++] = path;
	for( int i = first; i < argc; i++ ) arguments[count++] = argv[i];
	arguments[count] = NULL;
	return hl_vm_main(count,arguments);
}
#else
#	include <limits.h>
#	include <unistd.h>
#	ifdef __APPLE__
#		include <mach-o/dyld.h>
#	endif

int hl_vm_main( int argc, char *argv[] );

/* The absolute path of this executable, or NULL, with room to make the module's path from it. */
static char *executable_path( void ) {
	char *path = (char*)malloc(PATH_MAX + 16);
	if( path == NULL ) return NULL;
#	ifdef __APPLE__
	uint32_t size = PATH_MAX;
	if( _NSGetExecutablePath(path,&size) != 0 ) { free(path); return NULL; }
	char *resolved = realpath(path,NULL);
	free(path);
	if( resolved == NULL ) return NULL;
	path = (char*)realloc(resolved,strlen(resolved) + 16);
	return path;
#	else
	ssize_t length = readlink("/proc/self/exe",path,PATH_MAX);
	if( length <= 0 || length >= PATH_MAX ) { free(path); return NULL; }
	path[length] = 0;
	return path;
#	endif
}

int haxeon_app_run( int argc, char *argv[] ) {
	char *path = executable_path();
	char **arguments = (char**)malloc(sizeof(char*) * ((size_t)argc + 4));
	int count = 0, first = 1;
	if( path == NULL || arguments == NULL ) { fprintf(stderr,"haxeon app: cannot find its own executable\n"); return 70; }
#	ifdef __APPLE__
	/* X.app/Contents/MacOS/name: the module is X.app/Contents/Resources/name.hl */
	char *slash = strrchr(path,'/');
	if( slash != NULL && slash - path >= 15 && strncmp(slash - 15,"/Contents/MacOS",15) == 0 ) {
		memmove(slash + 4,slash,strlen(slash) + 1);
		memcpy(slash - 5,"Resources",9);
	}
#	endif
	strcat(path,".hl");
	arguments[count++] = argv[0];
	if( first < argc && strncmp(argv[first],DEBUG_OPTION,strlen(DEBUG_OPTION)) == 0 ) {
		arguments[count++] = "--debug-wait";
		arguments[count++] = "--debug";
		arguments[count++] = argv[first++] + strlen(DEBUG_OPTION);
	}
	if( first < argc && strncmp(argv[first],MODULE_OPTION,strlen(MODULE_OPTION)) == 0 )
		path = argv[first++] + strlen(MODULE_OPTION);
	arguments[count++] = path;
	for( int i = first; i < argc; i++ ) arguments[count++] = argv[i];
	arguments[count] = NULL;
	return hl_vm_main(count,arguments);
}
#endif
