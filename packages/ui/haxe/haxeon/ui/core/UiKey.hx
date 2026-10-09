package haxeon.ui.core;

/** Normalized NativeKit key values used for framework-level defaults. */
class UiKey {
	public static inline var Space:Int = 32;
	public static inline var Enter:Int = 257;
	public static inline var Tab:Int = 258;
	public static inline var Backspace:Int = 259;
	public static inline var Insert:Int = 260;
	public static inline var Delete:Int = 261;
	public static inline var F2:Int = 291;
	public static inline var F5:Int = 294;
	public static inline var F10:Int = 299;
	public static inline var Menu:Int = 348;
	public static inline var Down:Int = 264;
	public static inline var Up:Int = 265;
	public static inline var PageUp:Int = 266;
	public static inline var PageDown:Int = 267;
	public static inline var Right:Int = 262;
	public static inline var Left:Int = 263;
	public static inline var Home:Int = 268;
	public static inline var End:Int = 269;
	public static inline var Escape:Int = 256;
	public static inline var Comma:Int = 44;
	public static inline var Slash:Int = 47;
	public static inline var B:Int = 66;
	public static inline var D:Int = 68;
	public static inline var F:Int = 70;
	public static inline var G:Int = 71;
	public static inline var H:Int = 72;
	public static inline var J:Int = 74;
	public static inline var W:Int = 87;
	public static inline var A:Int = 65;
	public static inline var C:Int = 67;
	public static inline var K:Int = 75;
	public static inline var P:Int = 80;
	public static inline var R:Int = 82;
	public static inline var S:Int = 83;
	public static inline var Y:Int = 89;
	public static inline var Z:Int = 90;
	public static inline var V:Int = 86;
	public static inline var X:Int = 88;

	public static inline function isContextMenuRequest(key:Int, modifiers:Int):Bool
		return key == Menu || (key == F10 && (modifiers & UiModifier.Shift) != 0);
}
