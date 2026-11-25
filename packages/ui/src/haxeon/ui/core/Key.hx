package haxeon.ui.core;

/** Caller-chosen stable key; the validated string is the complete identity value. */
abstract Key(String) {
	/** A key for `value`, which identifies a widget among its siblings. Throws when it is empty. */
	public inline function new(value:String) {
		if (value == null || value.length == 0) throw "Widget keys must not be empty";
		this = value;
	}

	/** The key as text. */
	public inline function rawValue():String return this;
}
