package haxeon.ui.core;

/** Modifier bit values shared with NativeKit input events. */
enum abstract UiModifier(Int) implements Flags {
	var Shift = 1 << 0;
	var Control = 1 << 1;
	var Alt = 1 << 2;
	var Super = 1 << 3;
	var CapsLock = 1 << 4;
	var NumLock = 1 << 5;
}
