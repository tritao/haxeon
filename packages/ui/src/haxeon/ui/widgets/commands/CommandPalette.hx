package haxeon.ui.widgets.commands;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.core.UiEvent;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Align;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;

import haxeon.ui.widgets.commands.SearchPicker;
/** Searchable, virtualized command launcher suitable for editor key palettes. */
class CommandPalette implements View {
	/** Identifies the palette among its siblings, so its state survives rebuilds. Required, and never empty. */
	public final key:String;

	/** The registry the commands come from; the build context's when null. */
	public final registry:Null<CommandRegistry>;

	/** What the commands act on; the build context's when null. */
	public final invocationContext:Null<CommandContext>;

	/** Its left edge, unless `centered`. */
	public final x:Float;

	/** Its top edge, unless `centered`. */
	public final y:Float;

	/** The search text, which filters the commands by label. */
	public final query:String;
	/** Center the palette in the viewport, fitting its list into smaller windows. */
	public final centered:Bool;

	/** Called when the palette closes without a choice. */
	public final onDismiss:Null<Void->Void>;

	/** Called with the outcome of each command run. */
	public final onResult:Null<CommandResult->Void>;

	/** A palette searching every registered command, starting with `query`. Throws when `key` is empty. */
	public function new(key:String, ?registry:CommandRegistry, ?invocationContext:CommandContext,
			x:Float = 0.0, y:Float = 0.0, query:String = "",
			?onDismiss:Void->Void, ?onResult:CommandResult->Void, centered:Bool = false) {
		if (key == null || key.length == 0)
			throw "Command palettes require a stable key";
		this.key = key;
		this.registry = registry;
		this.invocationContext = invocationContext;
		this.x = x;
		this.y = y;
		this.query = query == null ? "" : query;
		this.centered = centered;
		this.onDismiss = onDismiss;
		this.onResult = onResult;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(new Key(key), function() {
			var commands = registry == null ? context.commands : registry;
			var actualContext = invocationContext == null ? context.commandContext : invocationContext;
			var queryState:State<String> = context.state(context.id("query"), query);
			var query = queryState.value;
			var selection:State<Int> = context.state(context.id("selection"), -1);
			var model = new CommandPaletteModel(commands, actualContext, query, selection.value,
				function(next) {
					queryState.update(next);
					selection.update(-1);
				},
					function(next) selection.update(next), onResult, onDismiss);
			var listHeight = Math.min(Math.max(36, model.count() * 36),
				Math.max(36, Math.min(320, context.viewportHeight - 80)));
			return new SearchPicker(key, model,
				(_, index, selected, hovered, _) -> model.buildItem(index, selected, hovered), function() {
					if (onDismiss != null) onDismiss();
				}, function() {}, width: 504, rowHeight: 36, maxListHeight: 320, x:,
					y: centered ? Math.max(8, (context.viewportHeight - listHeight - 58) / 2) : y, centered:,
					label: "Command palette", placeholder: "Search commands", dimBackdrop: true, menuSurface: false,
					layerZIndex: centered ? 1000 : 0).build(context);
		});
	}
}

private class CommandPaletteModel implements SearchPickerModel {
	public final commands:Array<Command>;
	final context:CommandContext;
	final registry:CommandRegistry;
	final queryValue:String;
	var selected:Int;
	final onQuery:String->Void;
	final onSelection:Int->Void;
	final onResult:Null<CommandResult->Void>;
	final onDismiss:Null<Void->Void>;

	public function new(registry:CommandRegistry, context:CommandContext, query:String, selected:Int,
			onQuery:String->Void, onSelection:Int->Void, onResult:Null<CommandResult->Void>,
			onDismiss:Null<Void->Void>) {
		commands = [];
		this.context = context == null ? new CommandContext() : context;
		this.queryValue = query;
		this.selected = selected;
		this.onQuery = onQuery;
		this.onSelection = onSelection;
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
	public function selectedIndex():Int
		return selected >= 0 && selected < commands.length && enabledAt(selected) ? selected : firstEnabledIndex();
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
	public function navigate(key:UiKey, modifiers:UiModifier, pageSize:Int):Void {
		if (key == UiKey.Enter) {
			activate(selectedIndex());
			return;
		}
		if (firstEnabledIndex() < 0) return;
		var step = key == UiKey.Up || key == UiKey.PageUp ? -1 : 1;
		var count = key == UiKey.PageUp || key == UiKey.PageDown ? pageSize : 1;
		var next = selectedIndex();
		if (next < 0 && step < 0) next = 0;
		for (_ in 0...count) for (_ in 0...commands.length) {
			next = (next + step + commands.length) % commands.length;
			if (enabledAt(next)) break;
		}
		selected = next;
		onSelection(next);
	}
	public function buildItem(index:Int, selected:Bool, hovered:Bool):View
		return new CommandPaletteItem(commands[index].label, enabledAt(index), commands[index].isChecked(context),
			selected, hovered);
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
		this.selected = selected;
		this.hovered = hovered;
	}

	public function build(context:BuildContext):ViewRoot {
		var color = !enabled ? context.theme.tokens.textDisabled : selected
			? context.theme.tokens.textOnAccent : context.theme.tokens.textPrimary;
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fixed(36.0);
		rowStyle.padding = new Insets(12.0, 0.0, 12.0, 0.0);
		rowStyle.childGap = 8.0;
		rowStyle.background = selected ? context.theme.tokens.accent : hovered
			? context.theme.tokens.surfaceHover : context.theme.tokens.surfaceRaised;
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
