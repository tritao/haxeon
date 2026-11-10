package haxeon.ui.semantics;

/** State bits shared with NativeKit's accessibility backend. */
enum abstract AccessibilityState(Int) implements Flags {
	var Focusable = 1;
	var Focused = 2;
	var Selected = 4;
	var Checked = 8;
	var Disabled = 16;
	var ReadOnly = 32;
	var Multiline = 64;
	var Password = 128;
	var Expanded = 256;
	var Modal = 512;
	var Required = 1024;
	var Invalid = 2048;
	var Busy = 4096;
	var HasPopup = 8192;
}
