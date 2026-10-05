package nativekit.ui.widgets.commands;
import nativekit.ui.core.Command;
import nativekit.ui.widgets.controls.Button;
import nativekit.ui.widgets.controls.ButtonVariant;

import LayoutStyle;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.CommandContext;
import nativekit.ui.core.CommandRegistry;
import nativekit.ui.core.CommandResult;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import nativekit.ui.icons.IconName;

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
		var command = commands.get(commandId);
		if (command == null) {
			var missing = new Button("Missing command: " + commandId, style, null, key);
			missing.enabled = false;
			return missing.build(context);
		}
		var actualContext = invocationContext == null ? context.commandContext : invocationContext;
		var button = new Button(displayLabel == null ? command.label : displayLabel, style, function() {
			var result = commands.executeContext(commandId, actualContext);
			if (onResult != null)
				onResult(result);
		}, key);
		button.variant = variant;
		button.leadingIcon = leadingIcon;
		// An icon-only button takes the command's name; visible text names the button itself, so what a user
		// reads is what assistive technology announces (WCAG 2.5.3, label in name).
		if (displayLabel != null && displayLabel.length == 0)
			button.accessibilityLabel = command.label;
		button.enabled = command.isEnabled(actualContext);
		button.selected = command.isChecked(actualContext);
		button.classes = ["command-button"].concat(classes);
		return button.build(context);
	}
}
