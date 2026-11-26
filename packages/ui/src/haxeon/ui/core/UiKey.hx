package haxeon.ui.core;


import haxeon.ui.core.UiEvent;
/** Normalized NativeKit key values used for framework-level defaults. */
class UiKey {
	/** The space bar. */
	public static inline var Space:Int = 32;

	/** Return or Enter. */
	public static inline var Enter:Int = 257;

	/** Tab. */
	public static inline var Tab:Int = 258;

	/** Backspace. */
	public static inline var Backspace:Int = 259;

	/** Insert. */
	public static inline var Insert:Int = 260;

	/** Forward Delete. */
	public static inline var Delete:Int = 261;

	/** F2. */
	public static inline var F2:Int = 291;

	/** F5. */
	public static inline var F5:Int = 294;

	/** F6. */
	public static inline var F6:Int = 295;

	/** F10. */
	public static inline var F10:Int = 299;

	/** F12. */
	public static inline var F12:Int = 301;

	/** The context-menu key. */
	public static inline var Menu:Int = 348;

	/** Down arrow. */
	public static inline var Down:Int = 264;

	/** Up arrow. */
	public static inline var Up:Int = 265;

	/** Page Up. */
	public static inline var PageUp:Int = 266;

	/** Page Down. */
	public static inline var PageDown:Int = 267;

	/** Right arrow. */
	public static inline var Right:Int = 262;

	/** Left arrow. */
	public static inline var Left:Int = 263;

	/** Home. */
	public static inline var Home:Int = 268;

	/** End. */
	public static inline var End:Int = 269;

	/** Escape. */
	public static inline var Escape:Int = 256;

	/** Comma. */
	public static inline var Comma:Int = 44;

	/** Slash. */
	public static inline var Slash:Int = 47;

	/** The B key. */
	public static inline var B:Int = 66;

	/** The D key. */
	public static inline var D:Int = 68;

	/** The F key. */
	public static inline var F:Int = 70;

	/** The G key. */
	public static inline var G:Int = 71;

	/** The H key. */
	public static inline var H:Int = 72;

	/** The J key. */
	public static inline var J:Int = 74;

	/** The W key. */
	public static inline var W:Int = 87;

	/** The A key. */
	public static inline var A:Int = 65;

	/** The C key. */
	public static inline var C:Int = 67;

	/** The K key. */
	public static inline var K:Int = 75;

	/** The P key. */
	public static inline var P:Int = 80;

	/** The R key. */
	public static inline var R:Int = 82;

	/** The S key. */
	public static inline var S:Int = 83;

	/** The Y key. */
	public static inline var Y:Int = 89;

	/** The Z key. */
	public static inline var Z:Int = 90;

	/** The V key. */
	public static inline var V:Int = 86;

	/** The X key. */
	public static inline var X:Int = 88;

	/** Whether `key` with `modifiers` asks for a context menu from the keyboard: the Menu key, or Shift+F10. */
	public static inline function isContextMenuRequest(key:Int, modifiers:UiModifier):Bool
		return key == Menu || (key == F10 && modifiers.contains(UiModifier.Shift));
}
