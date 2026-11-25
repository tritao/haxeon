package haxeon.ui.core;

/** Modifier bit values shared with NativeKit input events. */
enum abstract UiModifier(Int) implements Flags {
	/** Either Shift key. */
	var Shift = 1 << 0;

	/** Either Control key. */
	var Control = 1 << 1;

	/** Either Alt (Option) key. */
	var Alt = 1 << 2;

	/** Either Super key: Command on macOS, the Windows key on Windows. */
	var Super = 1 << 3;

	/** Caps Lock is on. */
	var CapsLock = 1 << 4;

	/** Num Lock is on. */
	var NumLock = 1 << 5;
}
