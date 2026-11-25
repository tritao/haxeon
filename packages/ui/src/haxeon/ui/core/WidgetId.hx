package haxeon.ui.core;

/** Stable 31-bit identity used to reconnect ephemeral widgets across frames. */
class WidgetId {
	/** The id as a number, stable across frames for the same key path. */
	public final value:Int;

	/** The id `value`; `BuildContext.id` and `KeyScope.widgetId` make the ids of keyed widgets. */
	public function new(value:Int) {
		if (value <= 0)
			throw "Widget IDs must be positive 31-bit values";
		this.value = value;
	}

	/** Whether `other` names the same widget. */
	public inline function equals(other:WidgetId):Bool
		return other != null && value == other.value;

	/** The id as text, for diagnostics. */
	public function toString():String
		return Std.string(value);
}
