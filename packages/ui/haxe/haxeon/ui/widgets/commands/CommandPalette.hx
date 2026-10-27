package haxeon.ui.widgets.commands;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Align;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.CommandResult;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;

/** Searchable, virtualized command launcher suitable for editor key palettes. */
class CommandPalette implements View {
	public final key:String;
	public final registry:Null<CommandRegistry>;
	public final invocationContext:Null<CommandContext>;
	public final x:Float;
	public final y:Float;
	public var query:String;
	/** Center the palette in the viewport, fitting its list into smaller windows. */
	public var centered:Bool;
	public var onDismiss:Null<Void->Void>;
	public var onResult:Null<CommandResult->Void>;

	public function new(key:String, ?registry:CommandRegistry, ?invocationContext:CommandContext,
			x:Float = 0.0, y:Float = 0.0, query:String = "",
			?onDismiss:Void->Void, ?onResult:CommandResult->Void) {
		if (key == null || key.length == 0)
			throw "Command palettes require a stable key";
		this.key = key;
		this.registry = registry;
		this.invocationContext = invocationContext;
		this.x = x;
		this.y = y;
		this.query = query == null ? "" : query;
		centered = false;
		this.onDismiss = onDismiss;
		this.onResult = onResult;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var commands = registry == null ? context.commands : registry;
			var actualContext = invocationContext == null ? context.commandContext : invocationContext;
			var queryState:State<String> = context.state(context.id("query"), query);
			query = queryState.value;
			var selectionQuery:State<String> = context.state(context.id("selection-query"), query);
			var selection:State<Int> = context.state(context.id("selection"), -1);
			var model = new CommandPaletteModel(commands, actualContext, query, selection,
				function(next) { query = next; queryState.update(next); }, onResult, onDismiss);
			if (selectionQuery.value != query || selection.value < 0 || selection.value >= model.count()) {
				selectionQuery.update(query);
				selection.update(model.firstEnabledIndex());
			}
			var picker = context.resourceState(context.id("picker"), function() return new SearchPicker(key, model,
				function(_, index, selected, hovered, _) return model.buildItem(index, selected, hovered),
				function() {}, function() {}), function(_) {}).value;
			picker.model = model;
			picker.buildRow = function(_, index, selected, hovered, _) return model.buildItem(index, selected, hovered);
			picker.onDismiss = function() { if (onDismiss != null) onDismiss(); };
			picker.onChanged = function() context.commands.refresh();
			picker.width = 504;
			picker.rowHeight = 36;
			picker.maxListHeight = 320;
			picker.label = "Command palette";
			picker.placeholder = "Search commands";
			picker.centered = centered;
			picker.x = x;
			var listHeight = Math.min(Math.max(36, model.count() * 36), Math.max(36, Math.min(320, context.viewportHeight - 80)));
			picker.y = centered ? Math.max(8, (context.viewportHeight - listHeight - 58) / 2) : y;
			picker.dimBackdrop = true;
			picker.menuSurface = false;
			picker.layerZIndex = centered ? 1000 : 0;
			return picker.build(context);
		});
	}
}

private class CommandPaletteModel implements SearchPickerModel {
	public final commands:Array<Command>;
	final context:CommandContext;
	final registry:CommandRegistry;
	final queryValue:String;
	final selection:State<Int>;
	final onQuery:String->Void;
	final onResult:Null<CommandResult->Void>;
	final onDismiss:Null<Void->Void>;

	public function new(registry:CommandRegistry, context:CommandContext, query:String, selection:State<Int>,
			onQuery:String->Void, onResult:Null<CommandResult->Void>, onDismiss:Null<Void->Void>) {
		commands = [];
		this.context = context == null ? new CommandContext() : context;
		this.queryValue = query;
		this.selection = selection;
		this.onQuery = onQuery;
		this.onResult = onResult;
		this.onDismiss = onDismiss;
		var needle = query == null ? "" : query.toLowerCase();
		for (id in registry.ids()) {
			var command = registry.get(id);
			if (command != null && (needle.length == 0 || matches(command, needle))) commands.push(command);
		}
		this.registry = registry;
	}
	public function query():String return queryValue;
	public function selectedIndex():Int return selection.value;
	public function count():Int return commands.length;
	public function labelAt(index:Int):String return commands[index].label;
	public function enabledAt(index:Int):Bool return commands[index].isEnabled(context);
	public function setQuery(value:String):Void onQuery(value);
	public function firstEnabledIndex():Int {
		for (index in 0...commands.length) if (enabledAt(index)) return index;
		return -1;
	}
	public function activate(index:Int):Void {
		if (index < 0 || index >= commands.length || !enabledAt(index)) return;
		var result = registry.executeContext(commands[index].id, context);
		if (onResult != null) onResult(result);
		if (result.succeeded && onDismiss != null) onDismiss();
	}
	public function navigate(key:Int, modifiers:Int, pageSize:Int):Void {
		if (key == UiKey.Enter) { activate(selection.value); return; }
		if (firstEnabledIndex() < 0) return;
		var step = key == UiKey.Up || key == UiKey.PageUp ? -1 : 1;
		var count = key == UiKey.PageUp || key == UiKey.PageDown ? pageSize : 1;
		var next = selection.value;
		if (next < 0 && step < 0) next = 0;
		for (_ in 0...count) for (_ in 0...commands.length) {
			next = (next + step + commands.length) % commands.length;
			if (enabledAt(next)) break;
		}
		selection.update(next);
	}
	public function buildItem(index:Int, selected:Bool, hovered:Bool):View
		return new CommandPaletteItem(commands[index].label, enabledAt(index), commands[index].isChecked(context), selected, hovered);
	static function matches(command:Command, needle:String):Bool
		return command.id.toLowerCase().indexOf(needle) >= 0 || command.label.toLowerCase().indexOf(needle) >= 0;
}

private class CommandPaletteItem implements View {
	final label:String;
	final enabled:Bool;
	final checked:Bool;
	final selected:Bool;
	final hovered:Bool;

	public function new(label:String, enabled:Bool, checked:Bool, selected:Bool, hovered:Bool) {
		this.label = label;
		this.enabled = enabled;
		this.checked = checked;
		this.selected = selected; this.hovered = hovered;
	}

	public function build(context:BuildContext):RenderNode {
		var color = !enabled ? context.theme.tokens.textDisabled : selected ? context.theme.tokens.textOnAccent : context.theme.tokens.textPrimary;
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fixed(36.0);
		rowStyle.padding = new Insets(12.0, 0.0, 12.0, 0.0);
		rowStyle.childGap = 8.0;
		rowStyle.background = selected ? context.theme.tokens.accent : hovered ? context.theme.tokens.navigationHover : context.theme.tokens.navigationBackground;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		var children:Array<KeyedView> = [
			new KeyedView("label", new Text(label, null, color))
		];
		if (checked) {
			var checkStyle = new LayoutStyle();
			checkStyle.width = LayoutAxis.grow();
			checkStyle.height = LayoutAxis.fixed(16.0);
			children.push(new KeyedView("check", new Align("check", new Text("✓", null,
				color), LayoutAlignmentX.End,
				LayoutAlignmentY.Center, checkStyle)));
		}
		return new Row("command-result", children, rowStyle).build(context);
	}
}
