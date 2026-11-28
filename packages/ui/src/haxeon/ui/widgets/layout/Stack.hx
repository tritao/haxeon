package haxeon.ui.widgets.layout;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.View;

/** Parent-relative positioned composition with native rendering and Haxe hit testing. */
class Stack implements View {
	final key:Key;
	final layers:Array<StackChild>;

	/** The stack's box, which its layers are positioned in. */
	public final style:LayoutStyle;

	/** Layers placed at their own positions within one box, later and higher `zIndex` layers on top. */
	public function new(key:String, layers:Array<StackChild>, ?style:LayoutStyle) {
		this.key = new Key(key);
		this.layers = layers == null ? [] : layers.copy();
		this.style = style == null ? defaultStyle() : style.copy();
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, () -> {
			var id = context.rootId("stack");
			var root = context.styled(id, LayoutVisualKind.Box,
				new StyleIdentity("stack", key.rawValue, key.rawValue, null, ["stack"]), style);
			var computed = root.computedStyle;
			for (layer in layers) {
				var child = context.withStyleParent(computed,
					() -> context.withScope(new Key(layer.key), () -> {
						var placement = new RootModifier();
						placement.positioning = LayoutPositioning.Absolute;
						placement.positionX = layer.x;
						placement.positionY = layer.y;
						placement.zIndex = layer.zIndex;
						placement.clipToParent = layer.clipToParent;
						if (layer.width != null) placement.width = cast layer.width;
						if (layer.height != null) placement.height = cast layer.height;
						return context.build(layer.view, placement);
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
	/** Identifies the layer among the stack's layers. */
	public final key:String;
	/** What the layer shows. */
	public final view:View;
	/** Its left edge, from the stack's, in logical pixels. */
	public final x:Float;
	/** Its top edge, from the stack's, in logical pixels. */
	public final y:Float;
	/** Its order: higher layers draw on top and take the pointer first. */
	public final zIndex:Int;
	/** Its width; the view's own when null. */
	public final width:Null<LayoutAxis>;
	/** Its height; the view's own when null. */
	public final height:Null<LayoutAxis>;
	/** Whether the stack's box clips it. */
	public final clipToParent:Bool;

	/** A layer showing `view` at (`x`, `y`). */
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
