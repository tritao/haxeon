package haxeon.ui.widgets.collections;

import haxeon.ui.LayoutSizing;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.collections.VirtualViewport;

/** Fixed-height virtual list composed from ordinary rows inside ScrollView. */
class VirtualList implements View {
	public final key:String;
	public final itemCount:Int;
	public final itemHeight:Float;
	public final viewportStyle:LayoutStyle;
	public final virtualization:VirtualizationPolicy;
	public var controller(default, null):ScrollController;
	public var materializedFirst(default, null):Int;
	public var materializedLast(default, null):Int;
	final itemBuilder:Int->View;
	final keyForIndex:Null<Int->String>;
	final fallbackViewportHeight:Float;
	final suppliedController:Bool;

	public function new(key:String, itemCount:Int, itemHeight:Float, itemBuilder:Int->View,
			?viewportStyle:LayoutStyle, ?keyForIndex:Int->String, ?controller:ScrollController,
			viewportHeight:Float = 300.0, ?virtualization:VirtualizationPolicy) {
		if (key == null || key.length == 0 || itemCount < 0 || itemHeight <= 0.0 ||
			!finite(itemHeight) || itemBuilder == null || viewportHeight <= 0.0 ||
			!finite(viewportHeight))
			throw "VirtualList requires a stable key, valid dimensions, and an item builder";
		this.key = key;
		this.itemCount = itemCount;
		this.itemHeight = itemHeight;
		this.itemBuilder = itemBuilder;
		this.keyForIndex = keyForIndex;
		this.suppliedController = controller != null;
		this.controller = controller == null ? new ScrollController() : controller;
		this.fallbackViewportHeight = viewportHeight;
		this.viewportStyle = viewportStyle == null ? defaultViewportStyle(viewportHeight) :
			viewportStyle.copy();
		this.virtualization = virtualization == null ? new VirtualizationPolicy() : virtualization;
		materializedFirst = 0;
		materializedLast = 0;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			// Retain an internally owned controller, but never replace one supplied
			// by the caller. Keyboard reveal and scrolling must share one instance.
			if (!suppliedController) {
				var stored:State<ScrollController> = context.state(context.id("scroll-state"), controller);
				controller = stored.value;
			}
			var viewportHeight = controller.viewportHeight > 0.0 ? controller.viewportHeight :
				(viewportStyle.height.sizing == LayoutSizing.Fixed ? viewportStyle.height.value :
				fallbackViewportHeight);
			var virtualWindow = virtualization.fixed(itemCount, itemHeight, viewportHeight,
				controller.offsetY);
			var first = virtualWindow.first;
			var last = virtualWindow.last;
			materializedFirst = first;
			materializedLast = last;

			var rowViews:Array<KeyedView> = [];
			var beforeHeight = first * itemHeight;
			rowViews.push(new KeyedView("before", new Spacer("before-spacer",
				LayoutAxis.grow(), LayoutAxis.fixed(beforeHeight))));
			for (index in first...last) {
				var rowKey = keyForIndex == null ? Std.string(index) : keyForIndex(index);
				if (rowKey == null || rowKey.length == 0)
					throw 'VirtualList item $index has an empty key';
				var item = itemBuilder(index);
				if (item == null)
					throw 'VirtualList item builder returned null for index $index';
				var row = new VirtualCollectionRow("row", rowKey, item, itemCount, index, itemHeight);
				var slotKey = virtualization.recycleSlots ? 'slot:${index - first}' : 'item:$rowKey';
				rowViews.push(new KeyedView(slotKey, row));
			}
			var afterHeight = (itemCount - last) * itemHeight;
			rowViews.push(new KeyedView("after", new Spacer("after-spacer",
				LayoutAxis.grow(), LayoutAxis.fixed(afterHeight))));

			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.grow();
			contentStyle.height = LayoutAxis.fixed(itemCount * itemHeight);
			var content = new Column("virtual-content", rowViews, contentStyle);
			var scroll = new ScrollView("viewport", content, viewportStyle,
				ScrollAxis.Vertical, controller);
			var root = new RenderNode(context.id("list"), LayoutVisualKind.Box);
			root.layout.style.width = viewportStyle.width;
			root.layout.style.height = viewportStyle.height;
			var semantics = new Semantics(AccessibilityRole.Collection);
			semantics.setSize = itemCount;
			semantics.orientation = AccessibilityOrientation.Vertical;
			root.semantics = semantics;
			var viewport = context.withScope(new Key("scroll-view"), function() return scroll.build(context));
			root.add(viewport);
			return root;
		});
	}

	static function defaultViewportStyle(height:Float):LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.fixed(height);
		return result;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

private class VirtualCollectionRow implements View {
	final key:String;
	final itemKey:String;
	final child:View;
	final setSize:Int;
	final index:Int;
	final height:Float;

	public function new(key:String, itemKey:String, child:View, setSize:Int, index:Int,
			height:Float) {
		this.key = key;
		this.itemKey = itemKey;
		this.child = child;
		this.setSize = setSize;
		this.index = index;
		this.height = height;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var style = new LayoutStyle();
			style.width = LayoutAxis.grow();
			style.height = LayoutAxis.fixed(height);
			var node = new RenderNode(context.id("collection-item"), LayoutVisualKind.Box, style);
			var semantics = new Semantics(AccessibilityRole.CollectionItem);
			semantics.setSize = setSize;
			semantics.positionInSet = index + 1;
			node.semantics = semantics;
			node.add(new KeyedView('item:$itemKey', child).build(context));
			return node;
		});
	}
}
