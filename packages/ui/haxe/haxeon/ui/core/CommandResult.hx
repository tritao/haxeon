package haxeon.ui.core;

/** Outcome returned by a contextual command invocation. */
enum CommandStatus {
	/** It ran. */
	Executed;

	/** It did not apply here, so something else may handle the input. */
	NotHandled;

	/** It was not enabled. */
	Disabled;

	/** It refused, for the reason `message` gives, such as input it cannot act on. */
	Rejected(message:String);

	/** The user cancelled it, as by dismissing a dialog. */
	Cancelled(message:String);

	/** It failed with an error, described by `message`. */
	Failed(message:String);
}

/** Structured command outcome suitable for menus, palettes, and automation. */
class CommandResult {
	/** What happened. */
	public final status:CommandStatus;

	/** Whether running it changed anything, such as the document: false for a command that only looked. */
	public final changed:Bool;

	/** An outcome; the static constructors name the common ones. */
	public function new(status:CommandStatus, changed:Bool = false) {
		this.status = status;
		this.changed = changed;
	}

	/** Whether the command ran (`Executed`). */
	public var succeeded(get, never):Bool;
	inline function get_succeeded():Bool
		return switch (status) {
			case Executed: true;
			default: false;
		};

	/** Why it was rejected, cancelled or failed; null otherwise. */
	public var message(get, never):Null<String>;
	function get_message():Null<String>
		return switch (status) {
			case Rejected(value) | Cancelled(value) | Failed(value): value;
			default: null;
		};

	/** The command ran; `changed` says whether it changed anything. */
	public static function executed(changed:Bool = true):CommandResult
		return new CommandResult(Executed, changed);

	/** The command did not apply here. */
	public static function notHandled():CommandResult
		return new CommandResult(NotHandled);

	/** The command was not enabled. */
	public static function disabled():CommandResult
		return new CommandResult(Disabled);

	/** The command refused, for the reason `message` gives. */
	public static function rejected(message:String = "Command rejected"):CommandResult
		return new CommandResult(Rejected(message));

	/** The user cancelled the command. */
	public static function cancelled(message:String = "Command cancelled"):CommandResult
		return new CommandResult(Cancelled(message));

	/** The command failed with `error`, described as text. */
	public static function failed(error:Dynamic):CommandResult
		return new CommandResult(Failed(error == null ? "Command failed" : Std.string(error)));
}
