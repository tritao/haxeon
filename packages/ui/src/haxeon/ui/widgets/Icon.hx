package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.Image;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconData;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.Semantics;

private class ColorKey {
	public var red = -1.0;
	public var green = 0.0;
	public var blue = 0.0;
	public var alpha = 0.0;
	public var key = "";

	public function new() {}
}

/** Font-independent vector icon rendered from an embedded typed path. */
class Icon implements View {
	// Icons rebuild with the same few colors, so the text of a color is kept in a small table compared by value.
	static final colorKeys:Array<ColorKey> = [for (_ in 0...16) new ColorKey()];
	static final namePrefixes:Map<Int, String> = new Map();

	/** Identifies the icon among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** Which icon it shows. */
	public final name:IconName;

	/** The icon's box, `size` pixels square. */
	public final style:LayoutStyle;

	/** Its color; the theme's text color when null. */
	public final color:Null<Color>;

	/** Its accessible name; without one it is decorative and assistive technology skips it. */
	public final label:Null<String>;

	/** The icon `name`, `size` pixels square. Throws when `key` is empty or `size` is not positive and finite. */
	public function new(key:String, name:IconName, size:Float = 16.0, ?color:Color, ?label:String) {
		if (key == null || key.length == 0
			|| size <= 0.0 || !Math.isFinite(size)) throw "Icons require a stable key and positive finite size";
		this.key = key;
		this.name = name;
		this.color = color;
		this.label = label;
		style = new LayoutStyle();
		style.width = LayoutAxis.fixed(size);
		style.height = LayoutAxis.fixed(size);
	}

	static function colorKey(color:Color):String {
		var slot = (Std.int(color.red * 255.0)
			* 31 + Std.int(color.green * 255.0) * 17 + Std.int(color.blue * 255.0) * 7 + Std.int(color.alpha * 255.0))
			& 15;
		var entry = colorKeys[slot];
		if (entry.red != color.red
			|| entry.green != color.green || entry.blue != color.blue || entry.alpha != color.alpha) {
			entry.red = color.red;
			entry.green = color.green;
			entry.blue = color.blue;
			entry.alpha = color.alpha;
			entry.key = color.red + ":" + color.green + ":" + color.blue + ":" + color.alpha;
		}
		return entry.key;
	}

	static function namePrefix(name:IconName):String {
		var id = Type.enumIndex(name);
		var known = namePrefixes.get(id);
		if (known == null) {
			known = "icon:" + Std.string(id) + ":";
			namePrefixes.set(id, known);
		}
		return known;
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(new Key(key), () -> {
			var node = context.createNode(context.rootId("icon"), LayoutVisualKind.Custom, style);
			node.hitTestSelf = false;
			var paintColor = color == null ? context.theme.tokens.textPrimary : color;
			var paintKey = namePrefix(name) + colorKey(paintColor);
			node.onPaint((canvas, geometry:ResolvedLayoutItem) -> {
				if (geometry.width <= 0.0 || geometry.height <= 0.0) return;
				canvas.save();
				defer canvas.restore();
				canvas.scale(geometry.width / 24.0, geometry.height / 24.0);
				canvas.strokeTransient(IconData.build(name), paintColor, 2.0, LineCap.Round, LineJoin.Round);
			}, paintKey);
			if (label != null) node.semantics = new Semantics(AccessibilityRole.Image, label);
			return node;
		});
	}
}
