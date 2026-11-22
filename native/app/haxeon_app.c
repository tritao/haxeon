/* An app runner's main: Haxeon's app entry point (libhaxeon-app, native/app/haxeon_app_main.c) does the rest. */
#ifdef _WIN32
#	include <wchar.h>
int haxeon_app_main( int argc, wchar_t *argv[] );
int wmain( int argc, wchar_t *argv[] ) { return haxeon_app_main(argc,argv); }
#else
int haxeon_app_main( int argc, char *argv[] );
int main( int argc, char *argv[] ) { return haxeon_app_main(argc,argv); }
#endif
