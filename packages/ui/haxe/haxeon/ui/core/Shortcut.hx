package haxeon.ui.core;

/** A normalized key/modifier chord used by application commands. */
class Shortcut {
	public final key:Int;
	public final modifiers:Int;

	public function new(key:Int, modifiers:Int = 0) {
		if (key <= 0)
			throw "Shortcuts require a positive key";
		this.key = key;
		this.modifiers = normalizeModifiers(modifiers);
	}

	/** Ignores lock-state bits; command chords are physical modifier chords. */
	public static function normalizeModifiers(modifiers:Int):Int
		return modifiers & (UiModifier.Shift | UiModifier.Control | UiModifier.Alt |
			UiModifier.Super);

	public function matches(key:Int, modifiers:Int):Bool
		return this.key == key && this.modifiers == normalizeModifiers(modifiers);

	public function equals(other:Null<Shortcut>):Bool
		return other != null && key == other.key && modifiers == other.modifiers;

	public function toString():String
		return 'Shortcut($key, $modifiers)';

	/** Text for people, such as "Ctrl+Shift+S". */
	public function label():String {
		var parts = modifierNames(false);
		parts.push(keyName(key, false));
		return parts.join("+");
	}

	/** Stable text for settings files, such as "ctrl+shift+s"; parse() reads it back. */
	public function serialize():String {
		var parts = modifierNames(true);
		parts.push(keyName(key, true));
		return parts.join("+");
	}

	/** Reads serialize() output; null when the text names no key or an unknown modifier. */
	public static function parse(text:String):Null<Shortcut> {
		if (text == null || text.length == 0)
			return null;
		var parts = text.toLowerCase().split("+");
		var modifiers = 0;
		for (index in 0...parts.length - 1)
			switch (parts[index]) {
				case "ctrl": modifiers |= UiModifier.Control;
				case "shift": modifiers |= UiModifier.Shift;
				case "alt": modifiers |= UiModifier.Alt;
				case "super": modifiers |= UiModifier.Super;
				default: return null;
			}
		var key = keyFor(parts[parts.length - 1]);
		return key <= 0 || isModifierKey(key) ? null : new Shortcut(key, modifiers);
	}

	/** Shift, Control, Alt and Super on either side: pressed alone they are not a shortcut. */
	public static function isModifierKey(key:Int):Bool
		return key >= 340 && key <= 347;

	function modifierNames(stable:Bool):Array<String> {
		var parts:Array<String> = [];
		if ((modifiers & UiModifier.Control) != 0)
			parts.push(stable ? "ctrl" : "Ctrl");
		if ((modifiers & UiModifier.Shift) != 0)
			parts.push(stable ? "shift" : "Shift");
		if ((modifiers & UiModifier.Alt) != 0)
			parts.push(stable ? "alt" : "Alt");
		if ((modifiers & UiModifier.Super) != 0)
			parts.push(stable ? "super" : "Super");
		return parts;
	}

	/** Names a key code; letters and digits are themselves, other keys use NAMED_KEYS or "key<code>". */
	public static function keyName(key:Int, stable:Bool = false):String {
		if ((key >= "A".code && key <= "Z".code) || (key >= "0".code && key <= "9".code)) {
			var character = String.fromCharCode(key);
			return stable ? character.toLowerCase() : character;
		}
		if (key >= 290 && key <= 314)
			return (stable ? "f" : "F") + Std.string(key - 289);
		var index = 0;
		while (index < NAMED_KEYS.length) {
			if (NAMED_KEYS[index] == Std.string(key))
				return NAMED_KEYS[index + (stable ? 1 : 2)];
			index += 3;
		}
		return "key" + Std.string(key);
	}

	static function keyFor(name:String):Int {
		if (name.length == 1) {
			var code = name.toUpperCase().charCodeAt(0);
			if ((code >= "A".code && code <= "Z".code) || (code >= "0".code && code <= "9".code))
				return code;
		}
		if (name.length >= 2 && name.charAt(0) == "f") {
			var number = Std.parseInt(name.substr(1));
			if (number != null && number >= 1 && number <= 25 && Std.string(number) == name.substr(1))
				return 289 + number;
		}
		var index = 0;
		while (index < NAMED_KEYS.length) {
			if (NAMED_KEYS[index + 1] == name)
				return Std.parseInt(NAMED_KEYS[index]);
			index += 3;
		}
		if (StringTools.startsWith(name, "key")) {
			var code = Std.parseInt(name.substr(3));
			if (code != null && code > 0 && Std.string(code) == name.substr(3))
				return code;
		}
		return 0;
	}

	/** Key code, stable name and label for keys other than letters, digits and F-keys (GLFW codes). */
	static final NAMED_KEYS:Array<String> = [
		"32", "space", "Space",
		"39", "apostrophe", "'",
		"44", "comma", ",",
		"45", "minus", "-",
		"46", "period", ".",
		"47", "slash", "/",
		"59", "semicolon", ";",
		"61", "equal", "=",
		"91", "bracketleft", "[",
		"92", "backslash", "\\",
		"93", "bracketright", "]",
		"96", "grave", "`",
		"256", "escape", "Esc",
		"257", "enter", "Enter",
		"258", "tab", "Tab",
		"259", "backspace", "Backspace",
		"260", "insert", "Insert",
		"261", "delete", "Delete",
		"262", "right", "Right",
		"263", "left", "Left",
		"264", "down", "Down",
		"265", "up", "Up",
		"266", "pageup", "Page Up",
		"267", "pagedown", "Page Down",
		"268", "home", "Home",
		"269", "end", "End"
	];
}
