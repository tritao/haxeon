package haxeon.ui.widgets.commands;
import haxeon.ui.core.Command;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.CommandResult;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;

/** Button whose label, enabled state, and action are owned by a Command. */
class CommandButton implements View {
	public final key:String;
	public final commandId:String;
	public final registry:Null<CommandRegistry>;
	public final invocationContext:Null<CommandContext>;
	public final style:Null<LayoutStyle>;
	/** Defaults to Secondary; callers mark primary commands explicitly. */
	public var variant:ButtonVariant;
	public var displayLabel:Null<String>;
	public var leadingIcon:Null<IconName>;
	/** Additional presentation classes for toolbar and other command surfaces. */
	public var classes:Array<String>;
	public var onResult:Null<CommandResult->Void>;

	public function new(key:String, commandId:String, ?registry:CommandRegistry,
			?invocationContext:CommandContext, ?style:LayoutStyle,
			?onResult:CommandResult->Void) {
		if (key == null || key.length == 0 || commandId == null || commandId.length == 0)
			throw "Command buttons require stable keys and command IDs";
		this.key = key;
		this.commandId = commandId;
		this.registry = registry;
		this.invocationContext = invocationContext;
		this.style = style == null ? null : style.copy();
		variant = ButtonVariant.Secondary;
		displayLabel = null;
		leadingIcon = null;
		classes = [];
		this.onResult = onResult;
	}

	public function build(context:BuildContext):RenderNode {
		var commands = registry == null ? context.commands : registry;
		var invocation = invocationContext;
		var command = commands.get(commandId);
		if (command == null) {
			var missing = new Button("Missing command: " + commandId, style, null, key, false
			);
			return missing.build(context);
		}
		var flags = invocation == null ? context.commandFlags(commands, commandId)
			: (command.isEnabled(invocation) ? 1 : 0) | (command.isChecked(invocation) ? 2 : 0);
		// Visible text names the control; an icon-only presentation retains the command's full name.
		var accessibleName = displayLabel != null && displayLabel.length == 0 ? command.label : null;
		var button = new Button(displayLabel == null ? command.label : displayLabel, style, function() {
			var actualContext = invocation == null ? context.commandContext : invocation;
			var result = commands.executeContext(commandId, actualContext);
			if (onResult != null)
				onResult(result);
		}, key, (flags & 1) != 0, variant, (flags & 2) != 0, ["command-button"].concat(classes)
		, leadingIcon, null, null, null, null, null, null, accessibleName);
		return button.build(context);
	}
}
