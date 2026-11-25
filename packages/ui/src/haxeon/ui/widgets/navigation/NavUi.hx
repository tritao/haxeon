package haxeon.ui.widgets.navigation;

import haxeon.ui.Color;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.WidgetId;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.widgets.text.Text;

/** Phone design tokens (docs/phone-ui/CONTRACTS.md) and small node builders shared by the navigation widgets. */
class NavUi {
	public static final surface:Color = rgb(0xffffff);
	public static final text:Color = rgb(0x16181d);
	public static final secondary:Color = rgb(0x555b66);
	public static final accent:Color = rgb(0x2f55c7);
	public static final idle:Color = rgb(0x9aa0aa);
	public static final rowBorder:Color = rgb(0xeceef2);
	public static final chipFill:Color = rgb(0xeceef2);
	public static final chipActiveFill:Color = rgb(0x16181d);
	public static final white:Color = rgb(0xffffff);
	public static final transparent:Color = Color.rgba(0.0, 0.0, 0.0, 0.0);
	public static final touchTarget:Float = 44.0;
	/** Slide duration in seconds for pushes, pops and sheets. */
	public static final slideSeconds:Float = 0.22;

	public static function rgb(value:Int, alpha:Float = 1.0):Color {
		return Color.fromBytes((value >> 16) & 255, (value >> 8) & 255, value & 255, Std.int(alpha * 255.0));
	}

	/** A styled box node under the current scope with the given widget type. */
	public static function box(context:BuildContext, id:WidgetId, type:String, key:String, style:LayoutStyle,
			?classes:Array<String>):RenderNode {
		var flags = context.interactionStates.get(id);
		var computed = context.resolveStyle(new StyleTarget(type, key, key, classes, [type], flags), style);
		var node = context.createNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
		node.setStyleIdentity(type, key, key, classes, [type]);
		node.states = flags;
		node.computedStyle = computed;
		return node;
	}

	/** A box under its own sub-scope, so several can share a parent. */
	public static function child(context:BuildContext, local:String, type:String, style:LayoutStyle,
			?classes:Array<String>):RenderNode {
		return context.withScope(new Key(local),
			function() return box(context, context.rootId(type), type, local, style, classes));
	}

	/** A single-line text node built under its own sub-scope. */
	public static function label(context:BuildContext, local:String, value:String, size:Float, color:Color,
			?letterSpacing:Float):RenderNode {
		return context.withScope(new Key(local), function() {
			var textOverride = new TextStyleOverride(null, size, letterSpacing);
			return new Text(value, null, color, textOverride).build(context);
		});
	}
}
