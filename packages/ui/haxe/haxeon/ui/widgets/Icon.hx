package haxeon.ui.widgets;

import haxeon.ui.Image;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconData;
import haxeon.ui.icons.IconName;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;

/** Font-independent vector icon rendered from an embedded typed path. */
class Icon implements View {
	public final key:String;
	public final name:IconName;
	public final style:LayoutStyle;
	public var color:Null<Color>;
	public var label:Null<String>;

	public function new(key:String, name:IconName, size:Float = 16.0,
			?color:Color, ?label:String) {
		if (key == null || key.length == 0 || size <= 0.0 || !Math.isFinite(size))
			throw "Icons require a stable key and positive finite size";
		this.key = key;
		this.name = name;
		this.color = color;
		this.label = label;
		style = new LayoutStyle();
		style.width = LayoutAxis.fixed(size);
		style.height = LayoutAxis.fixed(size);
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var node = new RenderNode(context.id("icon"), LayoutVisualKind.Custom, style);
			node.hitTestSelf = false;
			var paintColor = color == null ? context.theme.text : color;
			var paintKey = "icon:" + Std.string(name) + ":" + paintColor.red + ":" +
				paintColor.green + ":" + paintColor.blue + ":" + paintColor.alpha;
			node.onPaint(function(canvas, geometry:ResolvedLayoutItem) {
				if (geometry.width <= 0.0 || geometry.height <= 0.0)
					return;
				canvas.withState(function(target) {
					target.scale(geometry.width / 24.0, geometry.height / 24.0);
					target.strokeTransient(IconData.build(name), paintColor, 2.0,
						LineCap.Round, LineJoin.Round);
				});
			}, paintKey);
			if (label != null)
				node.semantics = new Semantics(AccessibilityRole.Image, label);
			return node;
		});
	}
}
