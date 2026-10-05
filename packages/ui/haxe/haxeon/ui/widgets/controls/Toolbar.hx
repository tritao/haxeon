package haxeon.ui.widgets.controls;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.commands.CommandButton;
import haxeon.ui.widgets.layout.Row;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Shared horizontal command surface for editor and simulation controls. */
class Toolbar implements View {
	public final key:String;
	public final commandIds:Array<String>;
	public final registry:Null<CommandRegistry>;
	public final invocationContext:Null<CommandContext>;
	public final style:LayoutStyle;

	public function new(key:String, commandIds:Array<String>, ?registry:CommandRegistry,
			?invocationContext:CommandContext, ?style:LayoutStyle) {
		if (key == null || key.length == 0)
			throw "Toolbars require a stable key";
		this.key = key;
		this.commandIds = commandIds == null ? [] : commandIds.copy();
		this.registry = registry;
		this.invocationContext = invocationContext;
		this.style = style == null ? defaultStyle() : style.copy();
		this.style.direction = LayoutDirection.LeftToRight;
	}

	public function build(context:BuildContext):RenderNode {
		var commands = registry == null ? context.commands : registry;
		var children:Array<KeyedView> = [];
		for (commandId in commandIds)
			if (commandId != null && commandId.length > 0 && commands.get(commandId) != null)
			{
				var button = new CommandButton(commandId, commandId, registry, invocationContext);
				button.variant = ButtonVariant.Navigation;
				children.push(new KeyedView(commandId, button));
			}
		return new Row(key, children, style).build(context);
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.childGap = 4.0;
		return result;
	}
}
