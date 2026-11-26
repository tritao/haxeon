package haxeon.ui.core;

import Observable;
import haxeon.ui.core.UiEvent;
import haxeon.ui.editing.EditorDocument;

/** An application action exposed to menus, toolbars, palettes, and shortcuts. */
class Command {
	/** Identifies the command: what menus, toolbars and settings name it by. Never empty. */
	public final id:String;
	/** Opt in to OS key repeats for editing actions; destructive/menu actions default off. */
	public var repeatable:Bool = false;

	/** The command's name as people see it, in menus and the command palette. */
	public final label:String;

	/** The key chord that runs it, if any; `addShortcut` adds more. */
	public final shortcut:Null<Shortcut>;
	final alternateShortcuts:Array<Shortcut>;
	final action:Void->Void;
	var contextualAction:Null<CommandContext->CommandResult>;
	final enabledPredicate:Null<Void->Bool>;
	final checkedPredicate:Null<Void->Bool>;
	var contextualEnabledPredicate:Null<CommandContext->Bool>;
	var contextualCheckedPredicate:Null<CommandContext->Bool>;

	/**
	 * A command that runs `action`, enabled while `enabled` says so (always, without it) and shown checked while
	 * `checked` does. Throws without an id, a label or an action.
	 */
	public function new(id:String, label:String, action:Void->Void,
			?shortcut:Shortcut, ?enabled:Void->Bool, ?checked:Void->Bool) {
		if (id == null || id.length == 0 || label == null || label.length == 0 || action == null)
			throw "Commands require a stable ID, label, and action";
		this.id = id;
		this.label = label;
		this.action = action;
		this.contextualAction = null;
		this.shortcut = shortcut;
		alternateShortcuts = [];
		this.enabledPredicate = enabled;
		this.checkedPredicate = checked;
		this.contextualEnabledPredicate = null;
		this.contextualCheckedPredicate = null;
	}

	/** Adds another chord for the same command without duplicating it in menus or palettes. */
	public function addShortcut(value:Shortcut):Command {
		if (value == null)
			throw "Alternate shortcuts cannot be null";
		if ((shortcut == null || !shortcut.equals(value))
			&& !Lambda.exists(alternateShortcuts, function(existing) return existing.equals(value)))
			alternateShortcuts.push(value);
		return this;
	}

	/** The shortcuts the command was registered with, primary first. */
	public function defaultShortcuts():Array<Shortcut> {
		var result:Array<Shortcut> = [];
		if (shortcut != null)
			result.push(shortcut);
		for (alternate in alternateShortcuts)
			result.push(alternate);
		return result;
	}

	/** Whether the key `key` with `modifiers` is one of the command's shortcuts. */
	public function matchesShortcut(key:UiKey, modifiers:UiModifier):Bool {
		if (shortcut != null && shortcut.matches(key, modifiers)) return true;
		for (alternate in alternateShortcuts)
			if (alternate.matches(key, modifiers)) return true;
		return false;
	}

	/** Creates a command whose action and predicates receive invocation context. */
	public static function contextual(id:String, label:String,
			action:CommandContext->CommandResult, ?shortcut:Shortcut,
			enabled:CommandContext->Bool = null,
			checked:CommandContext->Bool = null):Command {
		if (action == null)
			throw "Contextual commands require an action";
		var result = new Command(id, label, function() {}, shortcut);
		result.contextualAction = action;
		result.contextualEnabledPredicate = enabled;
		result.contextualCheckedPredicate = checked;
		return result;
	}

	/** Whether the command can run now, in `context` for a contextual command. */
	public function isEnabled(?context:CommandContext):Bool {
		if (contextualEnabledPredicate != null)
			return contextualEnabledPredicate(context == null ? new CommandContext() : context);
		return enabledPredicate == null || enabledPredicate();
	}

	/** Whether the command shows as checked now, as a toggle in a menu does, in `context` for a contextual command. */
	public function isChecked(?context:CommandContext):Bool {
		if (contextualCheckedPredicate != null)
			return contextualCheckedPredicate(context == null ? new CommandContext() : context);
		return checkedPredicate != null && checkedPredicate();
	}

	/** Executes the action when its current predicate allows it. */
	public function execute():Bool {
		if (contextualAction != null)
			return executeContext(new CommandContext()).succeeded;
		if (!isEnabled())
			return false;
		action();
		return true;
	}

	/** Executes with typed document, selection, viewport, and parameter context. */
	public function executeContext(context:CommandContext):CommandResult {
		var actual = context == null ? new CommandContext() : context;
		if (!isEnabled(actual))
			return CommandResult.disabled();
		if (contextualAction == null) {
			action();
			return CommandResult.executed();
		}
		try {
			var result = contextualAction(actual);
			return result == null ? CommandResult.failed("Command returned no result") : result;
		} catch (error:Dynamic) {
			return CommandResult.failed(error);
		}
	}
}

/** Typed accessors for arguments supplied by palettes, menus, or scripts. */
class CommandParameters {
	final values:Map<String, Dynamic>;

	/** No parameters. */
	public function new() {
		values = new Map();
	}

	/** Whether a value named `name` is set. */
	public function has(name:String):Bool
		return name != null && values.exists(name);

	/** Sets the value named `name`. Throws when `name` is empty. */
	public function set(name:String, value:Dynamic):Void {
		if (name == null || name.length == 0)
			throw "Command parameter names require a stable name";
		values.set(name, value);
	}

	/** Sets the text named `name`. */
	public function setString(name:String, value:String):Void
		set(name, value);

	/** Sets the flag named `name`. */
	public function setBool(name:String, value:Bool):Void
		set(name, value);

	/** Sets the number named `name`. */
	public function setFloat(name:String, value:Float):Void
		set(name, value);

	/** Sets the integer named `name`. */
	public function setInt(name:String, value:Int):Void
		set(name, value);

	/** The text named `name`, or null when it is missing or not text. */
	public function getString(name:String):Null<String> {
		var value = values.get(name);
		return value == null || !Std.isOfType(value, String) ? null : cast value;
	}

	/** The flag named `name`, or null when it is missing or not a flag. */
	public function getBool(name:String):Null<Bool> {
		var value = values.get(name);
		return value == null || !Std.isOfType(value, Bool) ? null : cast value;
	}

	/** The number named `name`, an integer included, or null when it is missing or not a number. */
	public function getFloat(name:String):Null<Float> {
		var value = values.get(name);
		if (value == null || (!Std.isOfType(value, Float) && !Std.isOfType(value, Int)))
			return null;
		return cast value;
	}

	/** The number named `name`, truncated to an integer, or null when it is missing or not a number. */
	public function getInt(name:String):Null<Int> {
		var value = values.get(name);
		if (value == null || (!Std.isOfType(value, Int) && !Std.isOfType(value, Float)))
			return null;
		return Std.int(value);
	}

	/** The value named `name`, whatever its type, or null. */
	public function get(name:String):Dynamic
		return values.get(name);

	/** An independent copy of the parameters. */
	public function copy():CommandParameters {
		var result = new CommandParameters();
		for (name in values.keys())
			result.set(name, values.get(name));
		return result;
	}
}

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

/** Stable invocation data shared by menus, shortcuts, palettes, and scripts. */
class CommandContext {
	/** The document the command acts on, if any. */
	public final document:Null<EditorDocument>;

	/** The ids of what is selected in it. */
	public final selection:Array<String>;

	/** The viewport the command was invoked in, if any. */
	public final viewportId:Null<String>;

	/** Arguments a palette, menu item or script passes. */
	public final parameters:CommandParameters;

	/** What invoked the command, as the application names it, for its logs and tracing; ui does not read it. */
	public final source:Null<String>;
	/** Optional application trace hook for inspector edits. */
	public var onPropertyEdit:Null<Dynamic->Void> = null;

	/** Invocation data for a command; everything is optional. */
	public function new(?document:EditorDocument, ?selection:Array<String>,
			?viewportId:String, ?parameters:CommandParameters, ?source:String) {
		this.document = document;
		this.selection = selection == null ? [] : selection.copy();
		this.viewportId = viewportId;
		this.parameters = parameters == null ? new CommandParameters() : parameters;
		this.source = source;
	}

	/** Whether anything is selected. */
	public var hasSelection(get, never):Bool;
	inline function get_hasSelection():Bool
		return selection.length > 0;

	/** Whether `id` is among the selected. */
	public function hasSelected(id:String):Bool
		return id != null && selection.indexOf(id) >= 0;
}

/** Observable holder for the immutable invocation context active in a build frame. */
internal class CommandContextState implements Observable {
	public var value:CommandContext;

	public function new()
		value = new CommandContext();
}
