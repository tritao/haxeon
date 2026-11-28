package haxeon.ui.widgets;
import haxeon.ui.core.ViewRoot;

import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.gestures.GestureRecognizer;

/** Attaches Haxe tap, double-tap, long-press, and drag recognizers to a child view. */
class GestureDetector implements View {
	final key:Key;
	final child:View;
	final recognizers:Array<GestureRecognizer>;

	/** The box around `child`. */
	public final style:LayoutStyle;

	/** Shows `child`, feeding its pointer events to `recognizers`. */
	public function new(key:String, child:View, recognizers:Array<GestureRecognizer>, ?style:LayoutStyle) {
		if (child == null) throw "GestureDetector requires a child view";
		this.key = new Key(key);
		this.child = child;
		this.recognizers = recognizers == null ? [] : recognizers.copy();
		this.style = style == null ? new LayoutStyle() : style.copy();
	}

	public function build(context:BuildContext):ViewRoot {
		return context.withScope(key, () -> {
			var node = context.createNode(context.rootId("gesture-detector"), LayoutVisualKind.Box, style);
			node.hitTestSelf = false;
			var content = context.withScope(new Key("content"), () -> child.build(context));
			node.add(content);
			var arena = context.gestures;
			node.on(UiEventKind.PointerDown, event -> {
				if (event.button == 0) {
					event.capturePointer();
					arena.pointerDown(content.id, event, recognizers);
				}
			});
			node.on(UiEventKind.PointerMove, event -> {
				arena.pointerMove(event);
			});
			node.on(UiEventKind.PointerUp, event -> {
				arena.pointerUp(event);
			});
			node.on(UiEventKind.PointerCancel, event -> {
				arena.pointerCancel(event.pointerId);
			});
			return node;
		});
	}
}
