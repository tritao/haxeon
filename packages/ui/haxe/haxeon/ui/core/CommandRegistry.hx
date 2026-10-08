package haxeon.ui.core;

import haxeon.ui.editing.EditHistory;
import haxeon.ui.editing.EditorDocument;


/**
 * Ordered application command registry. The last active scope wins, making
 * viewport, text-editor, and modal scopes able to override global shortcuts.
 */
class CommandRegistry {
	public static inline var GlobalScope:String = "global";
	final commands:Map<String, Command>;
	final commandScopes:Map<String, String>;
	final commandOrder:Array<String>;
	final activeScopeStack:Array<String>;
	/** User bindings that replace a command's registered shortcuts; an empty list unbinds it. */
	final customShortcuts:Map<String, Array<Shortcut>>;
	public var revision(default, null):Int;
	/** Optional observer for semantic command recording. */
	public var onInvoked:Null<String->CommandResult->Void> = null;

	public function new() {
		commands = new Map();
		commandScopes = new Map();
		commandOrder = [];
		activeScopeStack = [GlobalScope];
		customShortcuts = new Map();
		revision = 0;
	}

	/** Registers a command without replacing an existing ID. */
	public function register(command:Command, scope:String = GlobalScope):Void {
		validateScope(scope);
		if (command == null)
			throw "Command registry cannot register null commands";
		if (commands.exists(command.id))
			throw 'Command ${command.id} is already registered';
		commands.set(command.id, command);
		commandScopes.set(command.id, scope);
		commandOrder.push(command.id);
		revision++;
	}

	public function unregister(id:String):Bool {
		if (id == null || !commands.exists(id))
			return false;
		commands.remove(id);
		commandScopes.remove(id);
		commandOrder.remove(id);
		revision++;
		return true;
	}

	public function get(id:String):Null<Command>
		return id == null ? null : commands.get(id);

	public function ids():Array<String>
		return commandOrder.copy();

	/** The scope a command was registered in, or null for an unknown ID. */
	public function scopeOf(id:String):Null<String>
		return id == null ? null : commandScopes.get(id);

	/** The shortcuts that run a command now: the user's bindings, or else the registered ones. */
	public function shortcutsFor(id:String):Array<Shortcut> {
		var custom = customShortcuts.get(id);
		if (custom != null)
			return custom.copy();
		var command = get(id);
		return command == null ? [] : command.defaultShortcuts();
	}

	/**
	 * Replaces a command's shortcuts with the user's choice; an empty list
	 * unbinds it. Choosing the registered shortcuts again clears the custom
	 * binding. IDs that are not registered yet are kept for when they are.
	 */
	public function setShortcuts(id:String, shortcuts:Array<Shortcut>):Void {
		if (id == null || id.length == 0 || shortcuts == null)
			throw "Custom shortcuts require a command ID and a list";
		var unique:Array<Shortcut> = [];
		for (shortcut in shortcuts)
			if (shortcut != null && !Lambda.exists(unique, function(existing) return existing.equals(shortcut)))
				unique.push(shortcut);
		var command = get(id);
		if (command != null && sameShortcuts(unique, command.defaultShortcuts()))
			customShortcuts.remove(id);
		else
			customShortcuts.set(id, unique);
		revision++;
	}

	public function resetShortcuts(id:String):Void {
		if (customShortcuts.remove(id))
			revision++;
	}

	public function hasCustomShortcuts(id:String):Bool
		return customShortcuts.exists(id);

	/** Command IDs with custom bindings, including ones not registered yet. */
	public function customShortcutIds():Array<String>
		return [for (id in customShortcuts.keys()) id];

	/** Registered commands in the scope that the shortcut runs now, in registration order. */
	public function commandsBoundTo(shortcut:Shortcut, scope:String = GlobalScope):Array<String> {
		var result:Array<String> = [];
		for (id in commandOrder)
			if (commandScopes.get(id) == scope
				&& Lambda.exists(shortcutsFor(id), function(existing) return existing.equals(shortcut)))
				result.push(id);
		return result;
	}

	function matches(id:String, command:Command, key:Int, modifiers:Int):Bool {
		var custom = customShortcuts.get(id);
		if (custom == null)
			return command.matchesShortcut(key, modifiers);
		for (shortcut in custom)
			if (shortcut.matches(key, modifiers))
				return true;
		return false;
	}

	static function sameShortcuts(first:Array<Shortcut>, second:Array<Shortcut>):Bool {
		if (first.length != second.length)
			return false;
		for (index in 0...first.length)
			if (!first[index].equals(second[index]))
				return false;
		return true;
	}

	public function activeScopes():Array<String>
		return activeScopeStack.copy();

	/** Activates a context-specific scope until it is popped. */
	public function pushScope(scope:String):Void {
		validateScope(scope);
		if (scope == GlobalScope)
			return;
		activeScopeStack.push(scope);
		revision++;
	}

	public function popScope(scope:String):Bool {
		validateScope(scope);
		if (scope == GlobalScope)
			return false;
		var index = activeScopeStack.length - 1;
		while (index > 0) {
			if (activeScopeStack[index] == scope) {
				activeScopeStack.splice(index, 1);
				revision++;
				return true;
			}
			index--;
		}
		return false;
	}

	public function setActiveScopes(scopes:Array<String>):Void {
		activeScopeStack.resize(1);
		if (scopes != null)
			for (scope in scopes) {
				validateScope(scope);
				if (scope != GlobalScope)
					activeScopeStack.push(scope);
			}
		revision++;
	}

	/** Runs a callback with a temporary highest-priority scope. */
	public function withScope<T>(scope:String, callback:Void->T):T {
		if (callback == null)
			throw "Command scope callbacks cannot be null";
		pushScope(scope);
		try {
			var result = callback();
			popScope(scope);
			return result;
		} catch (error:Dynamic) {
			popScope(scope);
			throw error;
		}
	}

	/** Executes a command by ID when its current enabled predicate allows it. */
	public function execute(id:String):Bool {
		var command = get(id);
		if (command == null)
			return false;
		var succeeded = false;
		try succeeded = command.execute() catch (error:Dynamic) {
			notifyInvocation(id, CommandResult.failed(error));
			throw error;
		}
		notifyInvocation(id, succeeded ? CommandResult.executed() : CommandResult.disabled());
		if (!succeeded) return false;
		revision++;
		return true;
	}

	/** Executes a command by ID with an invocation context and structured result. */
	public function executeContext(id:String, context:CommandContext):CommandResult {
		var command = get(id);
		if (command == null)
			return CommandResult.notHandled();
		var result = command.executeContext(context);
		notifyInvocation(id, result);
		if (result.succeeded)
			revision++;
		return result;
	}

	/** Executes the highest-priority enabled command matching a key chord. */
	public function dispatch(key:Int, modifiers:Int):Bool {
		return dispatchContext(key, modifiers, null).succeeded;
	}

	/** Dispatches a key chord with context and returns the command outcome. */
	public function dispatchContext(key:Int, modifiers:Int,
			context:Null<CommandContext>):CommandResult {
		return dispatchContextInScopes(key, modifiers, context, null);
	}

	/**
	 * Dispatches through focused-node scopes before the registry's active scopes.
	 * The supplied path is ordered from root to focused node; the deepest scope
	 * therefore wins without mutating the registry's persistent scope stack.
	 */
	public function dispatchContextInScopes(key:Int, modifiers:Int,
			context:Null<CommandContext>, pathScopes:Null<Array<String>>, repeated:Bool = false):CommandResult {
		var normalized = Shortcut.normalizeModifiers(modifiers);
		var actual = context == null ? new CommandContext() : context;
		var scopes:Array<String> = [];
		var seen:Map<String, Bool> = new Map();
		if (pathScopes != null) {
			var pathIndex = pathScopes.length - 1;
			while (pathIndex >= 0) {
				var pathScope = pathScopes[pathIndex];
				if (pathScope != null && pathScope.length > 0) {
					validateScope(pathScope);
					if (!seen.exists(pathScope)) {
						scopes.push(pathScope);
						seen.set(pathScope, true);
					}
				}
				pathIndex--;
			}
		}
		var activeIndex = activeScopeStack.length - 1;
		while (activeIndex >= 0) {
			var activeScope = activeScopeStack[activeIndex];
			if (!seen.exists(activeScope)) {
				scopes.push(activeScope);
				seen.set(activeScope, true);
			}
			activeIndex--;
		}
		var disabled:Null<CommandResult> = null;
		for (scope in scopes) {
			var commandIndex = commandOrder.length - 1;
			while (commandIndex >= 0) {
				var id = commandOrder[commandIndex];
				var command = commands.get(id);
				if (command != null && commandScopes.get(id) == scope &&
					matches(id, command, key, normalized)) {
					if (!command.isEnabled(actual)) {
						disabled = CommandResult.disabled();
						notifyInvocation(id, disabled);
						break;
					}
					if (repeated && !command.repeatable) return CommandResult.executed(false);
					var result = command.executeContext(actual);
					notifyInvocation(id, result);
					if (result.succeeded) {
						revision++;
						return result;
					}
					return result;
				}
				commandIndex--;
			}
		}
		return disabled == null ? CommandResult.notHandled() : disabled;
	}

	function notifyInvocation(id:String, result:CommandResult):Void {
		if (onInvoked != null) onInvoked(id, result);
	}

	/** Invalidates command-bound views after external predicate state changes. */
	public function refresh():Void
		revision++;

	/** Adds standard undo/redo commands to this registry. */
	public function installHistoryCommands(history:EditHistory,
			undoId:String = "edit.undo", redoId:String = "edit.redo"):Void {
		if (history == null)
			throw "History commands require an edit history";
		register(new Command(undoId, "Undo", function() { history.undo(); },
			new Shortcut(UiKey.Z, UiModifier.Control), function() return history.canUndo));
		register(new Command(redoId, "Redo", function() { history.redo(); },
			new Shortcut(UiKey.Y, UiModifier.Control), function() return history.canRedo));
	}

	/** Adds undo/redo commands that follow the document in the invocation context. */
	public function installDocumentHistoryCommands(document:EditorDocument,
			undoId:String = "edit.undo", redoId:String = "edit.redo"):Void {
		if (document == null)
			throw "Document history commands require a document";
		register(Command.contextual(undoId, "Undo", function(context) {
			if (context.document != document)
				return CommandResult.rejected("The active document changed");
			return document.undo() ? CommandResult.executed() : CommandResult.rejected("Nothing to undo");
		}, new Shortcut(UiKey.Z, UiModifier.Control), function(context) {
			return context.document == document && document.canUndo;
		}));
		register(Command.contextual(redoId, "Redo", function(context) {
			if (context.document != document)
				return CommandResult.rejected("The active document changed");
			return document.redo() ? CommandResult.executed() : CommandResult.rejected("Nothing to redo");
		}, new Shortcut(UiKey.Y, UiModifier.Control), function(context) {
			return context.document == document && document.canRedo;
		}));
	}

	function validateScope(scope:String):Void {
		if (scope == null || scope.length == 0)
			throw "Command scopes require a stable name";
	}
}
