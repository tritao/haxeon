package haxeon.ui.widgets.commands;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.Popup;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextEditorState;
import haxeon.ui.widgets.text.TextField;

/** Search input and virtualized results with input-owned keyboard focus. Retain across builds. */
class SearchPicker implements View {
	final key:String;

	/** The results, query and selection. */
	public final model:SearchPickerModel;

	/**
	 * Builds a result row from the context, its index, whether it is selected and hovered, and a revision that changes
	 * when tooltips should close.
	 */
	public final buildRow:(BuildContext, Int, Bool, Bool, Int) -> View;

	/** Called when the user dismisses the picker, by Escape or a click outside. */
	public final onDismiss:Void->Void;

	/** Called after the query or selection changes, so the owner rebuilds. */
	public final onChanged:Void->Void;

	/** Its width, in logical pixels. */
	public final width:Float;

	/** The height of every result row. */
	public final rowHeight:Float;

	/** The tallest the result list grows before it scrolls. */
	public final maxListHeight:Float;

	/** Its left edge, unless `centered`. */
	public final x:Float;

	/** Its top edge. */
	public final y:Float;

	/** Whether it is centered horizontally in the viewport. */
	public final centered:Bool;

	/** The search field's accessible name. */
	public final label:String;

	/** The hint in the search field while it is empty. */
	public final placeholder:String;

	/** Text shown before the query in the search field, such as a mode marker. */
	public final prefix:String;

	/** Shown when there are no results. */
	public final emptyText:String;
	/** Keeps the whole query selected until the user edits it or moves the caret, so typing replaces a value the owner filled in. */
	public final selectQuery:Bool;

	/** Whether it keeps keyboard focus within itself. */
	public final modal:Bool;

	/** Whether the rest of the UI is dimmed behind it. */
	public final dimBackdrop:Bool;

	/** Whether it is drawn as a menu surface, with its border and shadow. */
	public final menuSurface:Bool;

	/** Its stacking order among overlays. */
	public final layerZIndex:Int;

	/**
	 * A picker over `model`'s results, `buildRow` building each. Throws when `key` is empty or there is no model or
	 * row builder.
	 */
	public function new(key:String,
			model:SearchPickerModel,
			buildRow:(BuildContext, Int, Bool, Bool, Int) -> View,
			onDismiss:Void->Void,
			onChanged:Void->Void,
			width:Float = 480,
			rowHeight:Float = 32,
			maxListHeight:Float = 360,
			x:Float = 0,
			y:Float = 10,
			centered:Bool = true,
			label:String = "Search",
			placeholder:String = "Search",
			prefix:String = "",
			emptyText:String = "No matching results",
			selectQuery:Bool = false,
			modal:Bool = true,
			dimBackdrop:Bool = false,
			menuSurface:Bool = true,
			layerZIndex:Int = 0) {
		if (key == null || key.length == 0
			|| model == null || buildRow == null) throw "SearchPicker requires a stable key, a model and a row builder";
		this.key = key;
		this.model = model;
		this.buildRow = buildRow;
		this.onDismiss = onDismiss;
		this.onChanged = onChanged;
		this.width = width;
		this.rowHeight = rowHeight;
		this.maxListHeight = maxListHeight;
		this.x = x;
		this.y = y;
		this.centered = centered;
		this.label = label;
		this.placeholder = placeholder;
		this.prefix = prefix;
		this.emptyText = emptyText;
		this.selectQuery = selectQuery;
		this.modal = modal;
		this.dimBackdrop = dimBackdrop;
		this.menuSurface = menuSurface;
		this.layerZIndex = layerZIndex;
	}

	public function build(context:BuildContext):ViewRoot {
		var state = context.lazyState(context.id("search-picker:" + key),
			() -> new SearchPickerState(selectQuery)).value;
		var tokens = context.theme.tokens;
		var actualWidth = Math.max(1, Math.min(width, context.viewportWidth - 24));
		var listHeight = Math.min(Math.max(rowHeight, model.count() * rowHeight),
			Math.max(rowHeight, Math.min(maxListHeight, context.viewportHeight - 80)));
		var query = model.query(), selected = model.selectedIndex();
		if (state.previousSelection != selected || state.previousQuery != query) state.tooltipDismissRevision++;
		var geometryChanged = state.previousRowHeight != rowHeight || state.previousListHeight != listHeight;
		if (state.previousQuery != query) {
			state.scroll.jumpTo(0, 0);
			state.hovered = -1;
		}
		if (state.previousSelection != selected || state.previousQuery != query || geometryChanged) {
			var top = selected * rowHeight;
			if (top < state.scroll.offsetY) state.scroll.jumpTo(0, top);
			else if (top + rowHeight > state.scroll.offsetY + listHeight) state.scroll.jumpTo(0,
				top + rowHeight - listHeight);
		}
		state.previousQuery = query;
		state.previousSelection = selected;
		state.previousRowHeight = rowHeight;
		state.previousListHeight = listHeight;
		var inputStyle = new LayoutStyle();
		inputStyle.width = LayoutAxis.grow();
		inputStyle.height = LayoutAxis.fixed(34);
		inputStyle.padding = new Insets(8, 4, 8, 4);
		inputStyle.background = tokens.surfaceSunken;
		// The field reads its selection provider again right after an edit, before the next build: the provider stops
		// imposing the selection at once, or the first typed character is selected and replaced by the second ("builds"
		// became "uilds").
		var release = function() state.selectQuery = false;
		var end = query.length;
		var input = new TextField("cv-input", query, function(value) {
			release();
			model.setQuery(value);
		}, inputStyle, placeholder, new TextStyle(15), tokens.textPrimary, placeholder: placeholder,
			onSubmit: function(_) {
			model.navigate(UiKey.Enter, haxeon.ui.core.UiEvent.UiModifier.empty(), 1);
			onChanged();
		},
			onSelectionChange: state.selectQuery ? _ -> release() : null,
			selectionProvider: state.selectQuery ? () -> (state.selectQuery ? new TextSelection(0, end) : null) : null);
		var focusedInput = new SearchPickerInput(input, function(ctx, node) {
			if (state.focusPending) {
				ctx.requestFocusAfterLayout(node.id);
				state.focusPending = false;
			}
		});
		var inputChildren:Array<KeyedView> = [];
		if (prefix.length > 0) inputChildren.push(new KeyedView("prefix",
			new Text(prefix, null, tokens.textSecondary, TextStyleOverride.text(15))));
		inputChildren.push(new KeyedView("field", focusedInput));
		var inputRowStyle = new LayoutStyle();
		inputRowStyle.width = LayoutAxis.grow();
		inputRowStyle.childAlignY = LayoutAlignmentY.Center;
		inputRowStyle.childGap = 6;
		var rows = [new KeyedView("input", new Row("cv-input-row", inputChildren, inputRowStyle))];
		var listStyle = new LayoutStyle();
		listStyle.width = LayoutAxis.grow();
		listStyle.height = LayoutAxis.fixed(listHeight);
		if (model.count() == 0) {
			listStyle.padding = new Insets(10, 6, 10, 6);
			rows.push(new KeyedView("empty",
				new Text(emptyText, listStyle, tokens.textSecondary, TextStyleOverride.text(14))));
		} else {
			rows.push(new KeyedView("list",
				new VirtualList("cv-state.scroll", model.count(), rowHeight, function(index) {
					var isSelected = model.enabledAt(index) && index == model.selectedIndex();
					return new SearchPickerRow(buildRow(context, index, isSelected, index == state.hovered,
						state.tooltipDismissRevision), model.labelAt(index), isSelected, model.enabledAt(index),
						function() {
							if (model.enabledAt(index)) model.activate(index);
							onChanged();
						}, function(value) {
						state.hovered = value ? index : -1;
						onChanged();
					});
				}, listStyle, null, state.scroll, listHeight, null, model)));
		}
		var contentStyle = new LayoutStyle();
		contentStyle.width = LayoutAxis.fixed(Math.max(1, actualWidth - 12));
		contentStyle.childGap = 6;
		var panelStyle = new LayoutStyle();
		panelStyle.width = LayoutAxis.fixed(actualWidth);
		panelStyle.padding = new Insets(6, 6, 6, 6);
		var popup = new Popup(key,
			new Column("cv-content", rows, contentStyle),
			centered ? Math.max(0, (context.viewportWidth - actualWidth) / 2) : x,
			y,
			panelStyle,
			onDismiss);
		popup.dimBackdrop = dimBackdrop;
		popup.menuSurface = menuSurface;
		popup.modal = modal;
		popup.label = label;
		popup.layerZIndex = layerZIndex;
		var modifier = new haxeon.ui.core.RootModifier();
		modifier.on(UiEventKind.Scroll, function(_) {
			state.tooltipDismissRevision++;
			onChanged();
		}, UiEventPhase.Capture);
		var recheckAfterLayout = geometryChanged;
		modifier.onResolved(function(_) {
			if (!recheckAfterLayout) return;
			recheckAfterLayout = false;
			state.previousSelection = -1;
			onChanged();
		});
		var navigate = function(event:UiEvent) {
			if (event.defaultPrevented) return;
			switch event.key {
				case UiKey.Up, UiKey.Down, UiKey.Enter, UiKey.Tab, UiKey.PageUp, UiKey.PageDown:
					model.navigate(event.key, event.modifiers, Std.int(Math.max(1, listHeight / rowHeight)));
					onChanged();
					event.preventDefault();
					event.stopPropagation();
				default:
			}
		};
		modifier.on(UiEventKind.KeyDown, navigate, UiEventPhase.Capture);
		modifier.on(UiEventKind.KeyRepeat, navigate, UiEventPhase.Capture);
		return context.build(popup, modifier);
	}
}

private class SearchPickerInput implements View {
	final input:TextField;
	final resolved:(BuildContext, ViewRoot) -> Void;
	public function new(input:TextField, resolved:(BuildContext, ViewRoot) -> Void) {
		this.input = input;
		this.resolved = resolved;
	}
	public function build(context:BuildContext):ViewRoot {
		var node = input.build(context);
		resolved(context, node);
		return node;
	}
}

private class SearchPickerRow implements View {
	final child:View;
	final label:String;
	final selected:Bool;
	final enabled:Bool;
	final activate:Void->Void;
	final hover:Bool->Void;
	public function new(child:View,
			label:String, selected:Bool, enabled:Bool, activate:Void->Void, hover:Bool->Void) {
		this.child = child;
		this.label = label;
		this.selected = selected;
		this.enabled = enabled;
		this.activate = activate;
		this.hover = hover;
	}
	public function build(context:BuildContext):ViewRoot {
		var semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.Semantics.AccessibilityRole.Button,
			label);
		semantics.states = selected
			? haxeon.ui.semantics.Semantics.AccessibilityState.Selected
			: haxeon.ui.semantics.Semantics.AccessibilityState.empty();
		if (!enabled) semantics.states |= haxeon.ui.semantics.Semantics.AccessibilityState.Disabled;
		semantics.actions = enabled
			? haxeon.ui.semantics.Semantics.AccessibilityAction.Activate
			: haxeon.ui.semantics.Semantics.AccessibilityAction.empty();
		var modifier = new haxeon.ui.core.RootModifier();
		modifier.semantics = semantics;
		modifier.enabled = enabled;
		// The handlers run after the build, when the row's root, and so its ID, is known.
		var rowId:Null<haxeon.ui.core.WidgetId> = null;
		modifier.on(UiEventKind.Click, function(event) {
			if (event.button != 0) return;
			activate();
			event.stopPropagation();
		});
		modifier.on(UiEventKind.Activate, function(event) {
			activate();
			event.stopPropagation();
		});
		// Descendant hover transitions bubble too; only the row boundary changes
		// whether its hover controls are visible.
		modifier.on(UiEventKind.HoverEnter, function(event) {
			if (event.target.equals(rowId)) hover(true);
		});
		modifier.on(UiEventKind.HoverLeave, function(event) {
			if (event.target.equals(rowId)) hover(false);
		});
		var node = context.build(child, modifier);
		rowId = node.id;
		return node;
	}
}

/** Application-owned results and selection; the picker owns focus and scrolling. */
interface SearchPickerModel extends haxeon.ui.widgets.collections.ListView.ListViewItemMetadata {
	/** The search text. */
	public function query():String;
	/** The selected result's index, or -1 for none. */
	public function selectedIndex():Int;
	/** How many results there are. */
	public function count():Int;
	public function labelAt(index:Int):String;
	public function enabledAt(index:Int):Bool;
	/** The user changed the search text to `value`. */
	public function setQuery(value:String):Void;
	/** Normalized UiKey/UiModifier values; pageSize is the visible row count. */
	public function navigate(key:UiKey, modifiers:UiModifier, pageSize:Int):Void;
	/** The user chose the result at `index`. */
	public function activate(index:Int):Void;
}

/** What a picker keeps between builds: its list's scroll, focus, hover, and what it last showed. */
private class SearchPickerState {
	public final scroll = new ScrollController();
	public var focusPending:Bool = true;
	public var previousQuery:String = "";
	public var previousSelection:Int = -1;
	public var previousRowHeight:Float = 0;
	public var previousListHeight:Float = 0;
	public var hovered:Int = -1;
	public var tooltipDismissRevision:Int = 0;
	/** Whether the query is still selected, as the picker opens with `selectQuery`; the first edit clears it. */
	public var selectQuery:Bool;

	public function new(selectQuery:Bool) this.selectQuery = selectQuery;
}
