package haxeon.ui.widgets.controls;

/** Immutable typed option used by Select. */
class SelectOption<T> {
	/** Identifies the option within its list. */
	public final key:String;

	/** The text the list shows for it. */
	public final label:String;

	/** The value choosing it selects. */
	public final value:T;

	/** Whether it can be chosen. */
	public final enabled:Bool;

	/** An option for a `Select` or `ComboBox`. Throws when `key` is empty. */
	public function new(key:String, label:String, value:T, enabled:Bool = true) {
		if (key == null || key.length == 0)
			throw "Select options require stable non-empty keys";
		this.key = key;
		this.label = label == null ? "" : label;
		this.value = value;
		this.enabled = enabled;
	}
}
