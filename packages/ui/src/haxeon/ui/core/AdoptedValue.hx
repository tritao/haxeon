package haxeon.ui.core;

/**
 * A value a control shows that both its caller and its user change (a slider's level, a select's choice, a split's
 * extent): the user's last choice, until the caller gives a different value than the last time, which it then adopts, as
 * `TextEditorState.adoptExternal` does for text. So a caller that keeps the value in a plain field and passes it back
 * unchanged keeps the user's edit, and one that resets it is followed. `BuildContext.adopted` gives a control its one.
 */
class AdoptedValue<T> {
	var given:T;
	final revision:State<Int>;

	/** What the control shows. */
	public var value(default, null):T;

	@:allow(haxeon.ui.core.BuildContext)
	function new(given:T, revision:State<Int>) {
		this.given = given;
		this.revision = revision;
		value = given;
	}

	/** Takes the caller's value when it differs from the last one given, and reads the revision, so `set` reruns the build. */
	@:allow(haxeon.ui.core.BuildContext)
	function adopt(next:T):Void {
		if (!haxeon.Equality.sameForChange(given, next)) {
			given = next;
			value = next;
		}
		revision.value;
	}

	/** The user's choice, shown from now on: the control's build runs again. */
	public function set(next:T):Void {
		if (haxeon.Equality.sameForChange(value, next)) return;
		value = next;
		revision.update(revision.value + 1);
	}
}
