package haxeon.ui.widgets.layout;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleTarget;

/** Parent-relative positioned composition with native rendering and Haxe hit testing. */
class Stack implements View {
	final key:Key;
	final layers:Array<StackChild>;
	public final style:LayoutStyle;

	public function new(key:String, layers:Array<StackChild>, ?style:LayoutStyle) {
		this.key = new Key(key);
		this.layers = layers == null ? [] : layers.copy();
		this.style = style == null ? defaultStyle() : style.copy();
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var id = context.rootId("stack");
			var computed = context.resolveStyle(new StyleTarget("stack", key.rawValue(), key.rawValue(), null,
				["stack"], context.interactionStates.get(id)),
				style);
			var root = context.createNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
			root.setStyleIdentity("stack", key.rawValue(), key.rawValue(), null, ["stack"]);
			root.states = context.interactionStates.get(id);
			root.computedStyle = computed;
			for (layer in layers) {
				var child = context.withStyleParent(computed,
					function() return context.withScope(new Key(layer.key), function() {
						var node = layer.view.build(context);
						node.layout.style.positioning = LayoutPositioning.Absolute;
						node.layout.style.positionX = layer.x;
						node.layout.style.positionY = layer.y;
						node.layout.style.zIndex = layer.zIndex;
						node.layout.style.clipToParent = layer.clipToParent;
						if (layer.width != null) node.layout.style.width = cast layer.width;
						if (layer.height != null) node.layout.style.height = cast layer.height;
						return node;
					}));
				root.add(child);
			}
			return root;
		});
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.grow();
		return result;
	}
}

/** A positioned child layer submitted to a Stack. */
class StackChild {
	public final key:String;
	public final view:View;
	public final x:Float;
	public final y:Float;
	public final zIndex:Int;
	public final width:Null<LayoutAxis>;
	public final height:Null<LayoutAxis>;
	public final clipToParent:Bool;

	public function new(key:String, view:View, x:Float = 0.0, y:Float = 0.0,
			zIndex:Int = 0, ?width:LayoutAxis, ?height:LayoutAxis,
			clipToParent:Bool = true) {
		if (key == null || key.length == 0 || view == null || !finite(x) || !finite(y) || zIndex < -32768
			|| zIndex > 32767)
			throw "Stack children require a key, finite position, view, and valid z-index";
		this.key = key;
		this.view = view;
		this.x = x;
		this.y = y;
		this.zIndex = zIndex;
		this.width = width;
		this.height = height;
		this.clipToParent = clipToParent;
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}
