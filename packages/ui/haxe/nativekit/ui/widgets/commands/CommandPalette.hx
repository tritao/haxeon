package nativekit.ui.widgets.commands;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.controls.SearchField;
import nativekit.ui.widgets.layout.Align;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.layout.Row;
import nativekit.ui.widgets.overlays.Popup;
import nativekit.ui.widgets.text.Text;

import Insets;
import LayoutAlignmentX;
import LayoutAlignmentY;
import LayoutAxis;
import LayoutStyle;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.Command;
import nativekit.ui.core.CommandContext;
import nativekit.ui.core.CommandRegistry;
import nativekit.ui.core.CommandResult;
import nativekit.ui.core.Key;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.State;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.View;
import nativekit.ui.widgets.collections.ListView;
import nativekit.ui.widgets.collections.ListViewItemMetadata;
import nativekit.ui.widgets.collections.ListViewModel;

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
			var queryChanged = selectionQuery.value != query;
			if (queryChanged) selectionQuery.update(query);
			var model = new CommandPaletteModel(commands, actualContext, query);
			var searchStyle = new LayoutStyle();
			searchStyle.width = LayoutAxis.grow();
			if (centered) searchStyle.height = LayoutAxis.fixed(38.0);
			var search = new SearchField("search", query, function(next) {
				query = next;
				queryState.update(next);
			}, searchStyle, "Search commands");
			var listStyle = new LayoutStyle();
			listStyle.width = LayoutAxis.grow();
			var listHeight = centered ? Math.min(320.0, Math.max(120.0, context.viewportHeight - 102.0)) : 320.0;
			listStyle.height = LayoutAxis.fixed(listHeight);
			var activate = function(index:Int) {
				if (index < 0 || index >= model.commands.length || !model.enabledAt(index))
					return;
				var result = commands.executeContext(model.commands[index].id, actualContext);
				if (onResult != null)
					onResult(result);
				if (result.succeeded && onDismiss != null)
					onDismiss();
			};
			var list = new ListView("commands", model, listStyle, null, listHeight,
				model.firstEnabledIndex(),
				null, activate, null, model);
			list.activateOnClick = true;
			search.onSubmit = function(_) activate(list.selectedIndex < 0
				? model.firstEnabledIndex() : list.selectedIndex);
			var contentStyle = new LayoutStyle();
			var contentWidth = centered ? Math.min(480.0, Math.max(200.0, context.viewportWidth - 32.0)) : 480.0;
			contentStyle.width = LayoutAxis.fixed(contentWidth);
			contentStyle.padding = new Insets(12.0, 12.0, 12.0, 12.0);
			contentStyle.childGap = 8.0;
			contentStyle.background = context.theme.panelBackground;
			var content = new Column("content", [
				new KeyedView("search", search),
				new KeyedView("commands", list)
			], contentStyle);
			var popupX = centered ? Math.max(8.0, (context.viewportWidth - contentWidth - 16.0) / 2.0) : x;
			var popupY = centered ? Math.max(8.0, (context.viewportHeight - listHeight - 86.0) / 2.0) : y;
			var popup = new Popup(key, content, popupX, popupY, null, onDismiss);
			popup.label = "Command palette";
			popup.modal = true;
			popup.dimBackdrop = true;
			if (centered) popup.layerZIndex = 1000;
			var root = popup.build(context);
			if (queryChanged)
				list.select(model.firstEnabledIndex());
			var navigate = function(event:nativekit.ui.core.UiEvent) {
				if (event.defaultPrevented ||
					(event.key != UiKey.Up && event.key != UiKey.Down))
					return;
				if (model.firstEnabledIndex() < 0) {
					event.preventDefault();
					return;
				}
				var step = event.key == UiKey.Down ? 1 : -1;
				var next = list.selectedIndex;
				if (next < 0 && step < 0) next = 0;
				for (_ in 0...model.commands.length) {
					next = (next + step + model.commands.length) % model.commands.length;
					if (model.enabledAt(next)) break;
				}
				list.select(next);
				list.scrollTo(next);
				event.preventDefault();
			};
			root.on(UiEventKind.KeyDown, navigate);
			root.on(UiEventKind.KeyRepeat, navigate);
			return root;
		});
	}
}

private class CommandPaletteModel implements ListViewModel implements ListViewItemMetadata {
	public final commands:Array<Command>;
	final context:CommandContext;

	public function new(registry:CommandRegistry, context:CommandContext, query:String) {
		commands = [];
		this.context = context == null ? new CommandContext() : context;
		var needle = query == null ? "" : query.toLowerCase();
		for (id in registry.ids()) {
			var command = registry.get(id);
			if (command != null && (needle.length == 0 || matches(command, needle)))
				commands.push(command);
		}
	}

	public function count():Int
		return commands.length;

	public function keyAt(index:Int):String
		return commands[index].id;

	public function labelAt(index:Int):String
		return commands[index].label;

	public function enabledAt(index:Int):Bool
		return commands[index].isEnabled(context);

	public function firstEnabledIndex():Int {
		for (index in 0...commands.length)
			if (enabledAt(index)) return index;
		return -1;
	}

	public function estimatedExtent():Float
		return 36.0;

	public function extentIsUniform():Bool
		return true;

	public function extentAt(index:Int):Float
		return 36.0;

	public function extentRevisionAt(index:Int):Int
		return 0;

	public function totalExtent():Null<Float>
		return commands.length * 36.0;

	public function buildItem(index:Int):View {
		var command = commands[index];
		return new CommandPaletteItem(command.label, enabledAt(index),
			command.isChecked(context));
	}

	public function revision():Int
		return 0;

	static function matches(command:Command, needle:String):Bool {
		return command.id.toLowerCase().indexOf(needle) >= 0 ||
			command.label.toLowerCase().indexOf(needle) >= 0;
	}
}

private class CommandPaletteItem implements View {
	final label:String;
	final enabled:Bool;
	final checked:Bool;

	public function new(label:String, enabled:Bool, checked:Bool) {
		this.label = label;
		this.enabled = enabled;
		this.checked = checked;
	}

	public function build(context:BuildContext):RenderNode {
		var color = enabled ? context.theme.tokens.textPrimary : context.theme.tokens.textDisabled;
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fixed(36.0);
		rowStyle.padding = new Insets(12.0, 0.0, 12.0, 0.0);
		rowStyle.childGap = 8.0;
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
