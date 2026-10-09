package haxeon.ui.widgets.commands;
import haxeon.ui.widgets.overlays.Menu;
import haxeon.ui.widgets.overlays.MenuItem;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.CommandResult;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Popup menu projection of registered commands, including live enablement. */
class CommandMenu implements View {
	public final key:String;
	public final commandIds:Array<String>;
	public final registry:Null<CommandRegistry>;
	public final invocationContext:Null<CommandContext>;
	public final x:Float;
	public final y:Float;
	public var onDismiss:Null<Void->Void>;
	public var onResult:Null<CommandResult->Void>;
	public var selectFirstOnOpen:Bool = false;

	public function new(key:String, commandIds:Array<String>, x:Float = 0.0, y:Float = 0.0,
			?registry:CommandRegistry, ?invocationContext:CommandContext,
			?onDismiss:Void->Void, ?onResult:CommandResult->Void) {
		if (key == null || key.length == 0)
			throw "Command menus require a stable key";
		this.key = key;
		this.commandIds = commandIds == null ? [] : commandIds.copy();
		this.x = x;
		this.y = y;
		this.registry = registry;
		this.invocationContext = invocationContext;
		this.onDismiss = onDismiss;
		this.onResult = onResult;
	}

	public function build(context:BuildContext):RenderNode {
		var commands = registry == null ? context.commands : registry;
		var actualContext = invocationContext == null ? context.commandContext : invocationContext;
		var items:Array<MenuItem> = [];
		for (commandId in commandIds) {
			var command = commands.get(commandId);
			if (command == null)
				continue;
			var capturedId = commandId;
			items.push(new MenuItem(capturedId, command.label, function() {
				var result = commands.executeContext(capturedId, actualContext);
				if (onResult != null)
					onResult(result);
			}, command.isEnabled(actualContext)));
		}
		var menu = new Menu(key, items, x, y, onDismiss);
		menu.selectFirstOnOpen = selectFirstOnOpen;
		return menu.build(context);
	}
}
