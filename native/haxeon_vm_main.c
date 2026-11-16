/* HashLink's entry point (vendor/hashlink/src/main.c), compiled under another name so the haxeon command (haxeon_main.c)
 * can start the VM with a module of its choosing: argument handling, debugger, diagnostics and module loading stay HashLink's. */
#define main hl_vm_main
#define wmain hl_vm_main
#include "main.c"
