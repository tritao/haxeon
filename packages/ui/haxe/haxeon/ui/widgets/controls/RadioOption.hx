package haxeon.ui.widgets.controls;

/** One keyed option in a RadioGroup. */
class RadioOption {
	/** Identifies the option within its group, so its button keeps its state across rebuilds. */
	public final key:String;

	/** The text shown beside the button. */
	public final label:String;

	/** The value the group takes when this option is chosen. */
	public final value:String;

	/** Whether the option can be chosen. */
	public final enabled:Bool;

	/** An option for a `RadioGroup`. Throws when `key` or `value` is empty. */
	public function new(key:String, label:String, value:String, enabled:Bool = true) {
		if (key == null || key.length == 0 || value == null || value.length == 0)
			throw "Radio options require stable keys and non-empty values";
		this.key = key;
		this.label = label == null ? "" : label;
		this.value = value;
		this.enabled = enabled;
	}
}
