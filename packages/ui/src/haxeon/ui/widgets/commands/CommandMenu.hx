package haxeon.ui.widgets.commands;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.widgets.overlays.Menu;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Popup menu projection of registered commands, including live enablement. */
class CommandMenu implements View {
	/** Identifies the menu among its siblings, so its state survives rebuilds. */
	public final key:String;

	/** The commands it lists, in order. */
	public final commandIds:Array<String>;

	/** The registry the commands come from; the build context's when null. */
	public final registry:Null<CommandRegistry>;

	/** What the commands act on; the build context's when null. */
	public final invocationContext:Null<CommandContext>;

	/** Its left edge, in its parent's coordinates. */
	public final x:Float;

	/** Its top edge, in its parent's coordinates. */
	public final y:Float;

	/** Called when the menu closes without a choice. */
	public var onDismiss:Null<Void->Void>;

	/** Called with the outcome of each command run. */
	public var onResult:Null<CommandResult->Void>;

	/** Whether the first enabled command is selected when the menu opens, as when it is opened from the keyboard. */
	public var selectFirstOnOpen:Bool = false;

	/** A menu of the commands `commandIds` at (`x`, `y`). */
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

	public function build(context:BuildContext):ViewRoot {
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
