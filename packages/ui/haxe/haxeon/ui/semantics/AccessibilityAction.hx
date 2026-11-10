package haxeon.ui.semantics;

/** Action capability bits shared with NativeKit's accessibility backend. */
enum abstract AccessibilityAction(Int) implements Flags {
	var Activate = 1;
	var Focus = 2;
	var SetValue = 4;
	var SetSelection = 8;
	var Increment = 16;
	var Decrement = 32;
	var ScrollForward = 64;
	var ScrollBackward = 128;
	var MoveNext = 256;
	var MovePrevious = 512;
	var Toggle = 1024;
	var Select = 2048;
	var Deselect = 4096;
	var Expand = 8192;
	var Collapse = 16384;
	var Dismiss = 32768;
	var ShowContextMenu = 65536;
	var ScrollIntoView = 131072;
}
