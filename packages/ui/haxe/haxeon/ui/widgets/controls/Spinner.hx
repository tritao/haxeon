package haxeon.ui.widgets.controls;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;

/** Indeterminate progress indicator rendered from reusable procedural paths. */
class Spinner implements View {
	/** Identifies the spinner among its siblings, so its animation carries on across rebuilds: required, and never empty. */
	public final key:String;

	/** What is loading, which assistive technology announces; "Loading" by default. */
	public final label:String;

	/** The animation drawn. */
	public final kind:SpinnerKind;

	/** The color drawn in; the theme's accent when null. */
	public final color:Null<Color>;

	/** How fast the animation runs, relative to its normal pace: finite and positive. */
	public final speed:Float;

	/** The spinner's box. */
	public final style:LayoutStyle;
	/** When false, the spinner holds its current frame and is not scheduled. */
	public var running:Bool;

	/** A running spinner. Throws when `key` is empty or `speed` is not finite and positive. */
	public function new(key:String,
			?label:String,
			?style:LayoutStyle,
			kind:SpinnerKind = SpinnerKind.Ring,
			?color:Color,
			speed:Float = 1.0) {
		if (key == null || key.length == 0) throw "Spinners require a stable key";
		if (!finite(speed) || speed <= 0.0) throw "Spinner speed must be finite and positive";
		this.key = key;
		this.label = label == null || label.length == 0 ? "Loading" : label;
		this.kind = kind;
		this.color = color;
		this.speed = speed;
		this.style = style == null ? defaultStyle() : style.copy();
		running = true;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var node = context.createNode(context.rootId("spinner"), LayoutVisualKind.Custom, style);
			var semantics = new Semantics(AccessibilityRole.ProgressBar, label, running ? "Indeterminate" : "Paused");
			if (running) semantics.states = AccessibilityState.Busy;
			node.semantics = semantics;

			var resolvedColor = color == null ? context.theme.accent : color;
			var stored:State<SpinnerPainter> = context.resourceState(node.id,
				function() return new SpinnerPainter(context.animations,
				resolvedColor,
				speed,
				kind), function(painter:SpinnerPainter) {
					painter.dispose();
				});
			var painter:SpinnerPainter = cast stored.value;
			painter.configure(kind, resolvedColor, speed);
			painter.setRunning(running);
			node.onPaint(function(canvas, geometry) painter.paintFrame(canvas, geometry));
			return node;
		});
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(24.0);
		result.height = LayoutAxis.fixed(24.0);
		return result;
	}

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;
}
