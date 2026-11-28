package haxeon.ui.widgets.commands;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.widgets.controls.Button;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;

/** Button whose label, enabled state, and action are owned by a Command. */
class CommandButton implements View {
	/** Identifies the button among its siblings, so its state survives rebuilds. */
	public final key:String;

	/** The command the button runs, whose label and enabled state it shows. */
	public final commandId:String;

	/** The registry the commands come from; the build context's when null. */
	public final registry:Null<CommandRegistry>;

	/** What the commands act on; the build context's when null. */
	public final invocationContext:Null<CommandContext>;

	/** The button's box; the default when null. */
	public final style:Null<LayoutStyle>;
	/** Defaults to Secondary; callers mark primary commands explicitly. */
	public final variant:ButtonVariant;

	/** Text shown in place of the command's label. */
	public final displayLabel:Null<String>;

	/** An icon before the label. */
	public final leadingIcon:Null<IconName>;
	/** Additional presentation classes for toolbar and other command surfaces. */
	public final classes:Array<String>;

	/** Called with the outcome of each command run. */
	public final onResult:Null<CommandResult->Void>;

	/** A button running the command `commandId`. */
	public function new(key:String,
			commandId:String,
			?registry:CommandRegistry,
			?invocationContext:CommandContext,
			?style:LayoutStyle,
			?onResult:CommandResult->Void,
			variant:ButtonVariant = ButtonVariant.Secondary,
			?displayLabel:String,
			?leadingIcon:IconName, ?classes:Array<String>) {
		if (key == null || key.length == 0
			|| commandId == null || commandId.length == 0) throw "Command buttons require stable keys and command IDs";
		this.key = key;
		this.commandId = commandId;
		this.registry = registry;
		this.invocationContext = invocationContext;
		this.style = style == null ? null : style.copy();
		this.classes = classes == null ? [] : classes.copy();
		this.onResult = onResult;
		this.variant = variant;
		this.displayLabel = displayLabel;
		this.leadingIcon = leadingIcon;
	}

	public function build(context:BuildContext):ViewRoot {
		var commands = registry == null ? context.commands : registry;
		var invocation = invocationContext;
		var command = commands.get(commandId);
		if (command == null) {
			var missing = new Button("Missing command: " + commandId, style, null, key, false);
			return missing.build(context);
		}
		var flags = invocation == null ? context.commandFlags(commands,
			commandId) : (command.isEnabled(invocation) ? 1 : 0) | (command.isChecked(invocation) ? 2 : 0);
		// Visible text names the control; an icon-only presentation retains the command's full name.
		var accessibleName = displayLabel != null && displayLabel.length == 0 ? command.label : null;
		var button = new Button(displayLabel == null ? command.label : displayLabel, style, () -> {
			var actualContext = invocation == null ? context.commandContext : invocation;
			var result = commands.executeContext(commandId, actualContext);
			if (onResult != null) onResult(result);
		}, key, (flags & 1) != 0, variant, (flags & 2) != 0,
			["command-button"].concat(classes), leadingIcon, null, null, null, null, null, null, accessibleName);
		return button.build(context);
	}
}
