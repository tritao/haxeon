package haxeon.ui.widgets.commands;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.Popup;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

/** Search input and virtualized results with input-owned keyboard focus. Retain across builds. */
class SearchPicker implements View {
	final key:String;
	public var model:SearchPickerModel;
	public var buildRow:(BuildContext, Int, Bool, Bool, Int)->View;
	public var onDismiss:Void->Void;
	public var onChanged:Void->Void;
	public var width:Float = 480;
	public var rowHeight:Float = 32;
	public var maxListHeight:Float = 360;
	public var x:Float = 0;
	public var y:Float = 10;
	public var centered:Bool = true;
	public var label:String = "Search";
	public var placeholder:String = "Search";
	public var prefix:String = "";
	public var emptyText:String = "No matching results";
	public var modal:Bool = true;
	public var dimBackdrop:Bool = false;
	public var menuSurface:Bool = true;
	public var layerZIndex:Int = 0;
	final scroll = new ScrollController();
	var focusPending:Bool = true;
	var previousQuery:String = "";
	var previousSelection:Int = -1;
	var previousRowHeight:Float = 0;
	var previousListHeight:Float = 0;
	var hovered:Int = -1;
	var tooltipDismissRevision:Int = 0;

	public function new(key:String, model:SearchPickerModel, buildRow:(BuildContext, Int, Bool, Bool, Int)->View,
			onDismiss:Void->Void, onChanged:Void->Void) {
		if (key == null || key.length == 0 || model == null || buildRow == null)
			throw "SearchPicker requires a stable key, a model and a row builder";
		this.key = key;
		this.model = model;
		this.buildRow = buildRow;
		this.onDismiss = onDismiss;
		this.onChanged = onChanged;
	}

	public function build(context:BuildContext):RenderNode {
		var tokens = context.theme.tokens;
		var actualWidth = Math.max(1, Math.min(width, context.viewportWidth - 24));
		var listHeight = Math.min(Math.max(rowHeight, model.count() * rowHeight),
			Math.max(rowHeight, Math.min(maxListHeight, context.viewportHeight - 80)));
		var query = model.query(), selected = model.selectedIndex();
		if (previousSelection != selected || previousQuery != query) tooltipDismissRevision++;
		var geometryChanged = previousRowHeight != rowHeight || previousListHeight != listHeight;
		if (previousQuery != query) { scroll.jumpTo(0, 0); hovered = -1; }
		if (previousSelection != selected || previousQuery != query || geometryChanged) {
			var top = selected * rowHeight;
			if (top < scroll.offsetY) scroll.jumpTo(0, top);
			else if (top + rowHeight > scroll.offsetY + listHeight) scroll.jumpTo(0, top + rowHeight - listHeight);
		}
		previousQuery = query;
		previousSelection = selected;
		previousRowHeight = rowHeight;
		previousListHeight = listHeight;
		var inputStyle = new LayoutStyle();
		inputStyle.width = LayoutAxis.grow(); inputStyle.height = LayoutAxis.fixed(34);
		inputStyle.padding = new Insets(8, 4, 8, 4); inputStyle.background = tokens.selectionField;
		var input = new TextField("cv-input", query, function(value) model.setQuery(value), inputStyle,
			placeholder, new TextStyle(15), tokens.textPrimary);
		input.placeholder = placeholder;
		input.onSubmit = function(_) { model.navigate(UiKey.Enter, 0, 1); onChanged(); };
		var focusedInput = new SearchPickerInput(input, function(ctx, node) {
			if (focusPending) { ctx.requestFocusAfterLayout(node.id); focusPending = false; }
		});
		var inputChildren:Array<KeyedView> = [];
		if (prefix.length > 0) inputChildren.push(new KeyedView("prefix", new Text(prefix, null, tokens.textSecondary, TextStyleOverride.text(15))));
		inputChildren.push(new KeyedView("field", focusedInput));
		var inputRowStyle = new LayoutStyle(); inputRowStyle.width = LayoutAxis.grow();
		inputRowStyle.childAlignY = LayoutAlignmentY.Center; inputRowStyle.childGap = 6;
		var rows = [new KeyedView("input", new Row("cv-input-row", inputChildren, inputRowStyle))];
		var listStyle = new LayoutStyle(); listStyle.width = LayoutAxis.grow(); listStyle.height = LayoutAxis.fixed(listHeight);
		if (model.count() == 0) {
			listStyle.padding = new Insets(10, 6, 10, 6);
			rows.push(new KeyedView("empty", new Text(emptyText, listStyle, tokens.textSecondary, TextStyleOverride.text(14))));
		} else {
			rows.push(new KeyedView("list", new VirtualList("cv-scroll", model.count(), rowHeight, function(index) {
				var isSelected = model.enabledAt(index) && index == model.selectedIndex();
				return new SearchPickerRow(buildRow(context, index, isSelected, index == hovered, tooltipDismissRevision),
					model.labelAt(index), isSelected, model.enabledAt(index),
					function() { if (model.enabledAt(index)) model.activate(index); onChanged(); },
					function(value) { hovered = value ? index : -1; onChanged(); });
			}, listStyle, null, scroll, listHeight, null, model)));
		}
		var contentStyle = new LayoutStyle(); contentStyle.width = LayoutAxis.fixed(Math.max(1, actualWidth - 12)); contentStyle.childGap = 6;
		var panelStyle = new LayoutStyle(); panelStyle.width = LayoutAxis.fixed(actualWidth); panelStyle.padding = new Insets(6, 6, 6, 6);
		var popup = new Popup(key, new Column("cv-content", rows, contentStyle),
			centered ? Math.max(0, (context.viewportWidth - actualWidth) / 2) : x, y, panelStyle, onDismiss);
		popup.dimBackdrop = dimBackdrop; popup.menuSurface = menuSurface; popup.modal = modal;
		popup.label = label; popup.layerZIndex = layerZIndex;
		var root = popup.build(context);
		root.on(UiEventKind.Scroll, function(_) { tooltipDismissRevision++; onChanged(); }, "capture");
		var recheckAfterLayout = geometryChanged;
		root.onResolved(function(_) {
			if (!recheckAfterLayout) return;
			recheckAfterLayout = false; previousSelection = -1; onChanged();
		});
		var navigate = function(event:UiEvent) {
			if (event.defaultPrevented) return;
			switch event.key {
				case UiKey.Up, UiKey.Down, UiKey.Enter, UiKey.Tab, UiKey.PageUp, UiKey.PageDown:
					model.navigate(event.key, event.modifiers, Std.int(Math.max(1, listHeight / rowHeight)));
					onChanged(); event.preventDefault(); event.stopPropagation();
				default:
			}
		};
		root.on(UiEventKind.KeyDown, navigate, "capture");
		root.on(UiEventKind.KeyRepeat, navigate, "capture");
		return root;
	}
}

private class SearchPickerInput implements View {
	final input:TextField;
	final resolved:(BuildContext, RenderNode)->Void;
	public function new(input:TextField, resolved:(BuildContext, RenderNode)->Void) { this.input = input; this.resolved = resolved; }
	public function build(context:BuildContext):RenderNode { var node = input.build(context); resolved(context, node); return node; }
}

private class SearchPickerRow implements View {
	final child:View;
	final label:String;
	final selected:Bool;
	final enabled:Bool;
	final activate:Void->Void;
	final hover:Bool->Void;
	public function new(child:View, label:String, selected:Bool, enabled:Bool, activate:Void->Void, hover:Bool->Void) {
		this.child = child; this.label = label; this.selected = selected; this.enabled = enabled;
		this.activate = activate; this.hover = hover;
	}
	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Button, label);
		node.semantics.states = selected ? haxeon.ui.semantics.AccessibilityState.Selected : 0;
		node.enabled = enabled;
		if (!enabled) node.semantics.states |= haxeon.ui.semantics.AccessibilityState.Disabled;
		node.semantics.actions = enabled ? haxeon.ui.semantics.AccessibilityAction.Activate : 0;
		node.on(UiEventKind.Click, function(event) {
			if (event.button != 0) return;
			activate(); event.stopPropagation();
		});
		node.on(UiEventKind.Activate, function(event) { activate(); event.stopPropagation(); });
		node.on(UiEventKind.HoverEnter, function(_) hover(true));
		node.on(UiEventKind.HoverLeave, function(_) hover(false));
		return node;
	}
}
