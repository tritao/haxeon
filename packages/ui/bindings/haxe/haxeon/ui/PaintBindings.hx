package haxeon.ui;

import haxe.ds.ObjectMap;

/** Tracks shared style and node views while their native slots are live. */
@:noCompletion
class PaintBindings {
	static final styles:ObjectMap<LayoutStyle, PaintBinding> = new ObjectMap();
	static final nodes:ObjectMap<LayoutNode, PaintBinding> = new ObjectMap();

	public static function style(value:LayoutStyle):Null<PaintBinding> return styles.get(value);
	public static function node(value:LayoutNode):Null<PaintBinding> return nodes.get(value);

	public static function attach(node:LayoutNode, store:PaintStore, index:Int):PaintBinding {
		var style = node.style, background = style.background, text = node.textColor;
		var topLeft = style.radiusTopLeft, topRight = style.radiusTopRight;
		var bottomLeft = style.radiusBottomLeft, bottomRight = style.radiusBottomRight;
		var generation = store.generation(index);
		store.setBackground(index, generation, background.red, background.green, background.blue, background.alpha);
		store.setRadii(index, generation, topLeft, topRight, bottomLeft, bottomRight);
		store.setTextColor(index, generation, text.red, text.green, text.blue, text.alpha);
		var binding = new PaintBinding(style, node, store, index, generation);
		binding.nextStyle = styles.get(style);
		binding.nextNode = nodes.get(node);
		styles.set(style, binding);
		nodes.set(node, binding);
		return binding;
	}

	public static function detach(binding:PaintBinding):Void {
		var style = binding.style, node = binding.node;
		var background = style.background, text = node.textColor;
		var topLeft = style.radiusTopLeft, topRight = style.radiusTopRight;
		var bottomLeft = style.radiusBottomLeft, bottomRight = style.radiusBottomRight;
		var current = styles.get(style), previous:Null<PaintBinding> = null;
		while (current != null && current != binding) { previous = current; current = current.nextStyle; }
		if (current == null) throw "Paint style binding is not live";
		if (previous == null) {
			if (current.nextStyle == null) styles.remove(style); else styles.set(style, current.nextStyle);
		} else previous.nextStyle = current.nextStyle;
		current = nodes.get(node); previous = null;
		while (current != null && current != binding) { previous = current; current = current.nextNode; }
		if (current == null) throw "Paint node binding is not live";
		if (previous == null) {
			if (current.nextNode == null) nodes.remove(node); else nodes.set(node, current.nextNode);
		} else previous.nextNode = current.nextNode;
		// When the last slot goes away, the detached values remain usable by callers.
		if (styles.get(style) == null) {
			style.background = background;
			style.radiusTopLeft = topLeft; style.radiusTopRight = topRight;
			style.radiusBottomLeft = bottomLeft; style.radiusBottomRight = bottomRight;
		}
		if (nodes.get(node) == null) node.textColor = text;
	}
}
