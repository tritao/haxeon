package haxeon.ui.core;

/** An application action exposed to menus, toolbars, palettes, and shortcuts. */
class Command {
	public final id:String;
	public final label:String;
	public final shortcut:Null<Shortcut>;
	final alternateShortcuts:Array<Shortcut>;
	final action:Void->Void;
	var contextualAction:Null<CommandContext->CommandResult>;
	final enabledPredicate:Null<Void->Bool>;
	final checkedPredicate:Null<Void->Bool>;
	var contextualEnabledPredicate:Null<CommandContext->Bool>;
	var contextualCheckedPredicate:Null<CommandContext->Bool>;

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
		if ((shortcut == null || !shortcut.equals(value)) &&
			!Lambda.exists(alternateShortcuts, function(existing) return existing.equals(value)))
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

	public function matchesShortcut(key:Int, modifiers:Int):Bool {
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

	public function isEnabled(?context:CommandContext):Bool {
		if (contextualEnabledPredicate != null)
			return contextualEnabledPredicate(context == null ? new CommandContext() : context);
		return enabledPredicate == null || enabledPredicate();
	}

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
