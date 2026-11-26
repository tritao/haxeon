package haxeon.ui.widgets.controls;

import Observable;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationController;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.State;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;

/**
 * Read-only progress indicator painted from a normalized numeric range. Its fields are observable: setting `value` or
 * `mode` reruns the bar's scope.
 */
class ProgressBar implements ScopeView implements Observable {
	/**
	 * Identifies the bar among its siblings, so its animation carries on across rebuilds: required, and never empty.
	 */
	public final key:String;

	/** What is in progress, which assistive technology announces. */
	public final label:Null<String>;

	/** How far the work has got, between `minimum` and `maximum`; ignored while `mode` is `Indeterminate`. */
	public var value:Float;

	/** The value of no progress. */
	public final minimum:Float;

	/** The value of complete progress: greater than `minimum`. */
	public final maximum:Float;

	/** The bar's box. */
	public final style:LayoutStyle;

	/** Whether the bar shows how far the work has got, or only that it is under way; `Determinate` by default. */
	public var mode:ProgressMode;
	/** Seconds used when a determinate value changes; zero disables interpolation. */
	public var animationDuration:Float;

	/**
	 * A bar showing `value` between `minimum` and `maximum`, clamped into that range. Throws when `key` is empty, a
	 * number is not finite, or the range is empty.
	 */
	public function new(key:String,
			value:Float,
			minimum:Float = 0.0,
			maximum:Float = 1.0,
			?label:String,
			?style:LayoutStyle) {
		if (key == null || key.length == 0 || !finite(value)
			|| !finite(minimum) || !finite(maximum)
			|| maximum <= minimum) throw "Progress values and range are invalid";
		this.key = key;
		this.label = label;
		this.value = clamp(value, minimum, maximum);
		this.minimum = minimum;
		this.maximum = maximum;
		this.style = style == null ? defaultStyle() : style.copy();
		mode = ProgressMode.Determinate;
		animationDuration = 0.22;
	}

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, ProgressBar)) return false;
		var other:ProgressBar = cast previous;
		return key == other.key && label == other.label && value == other.value && minimum == other.minimum
			&& maximum == other.maximum && mode == other.mode && animationDuration == other.animationDuration
			&& haxeon.Diff.mask(style, other.style) == 0;
	}

	public function buildBody(context:BuildContext):RenderNode return buildControl(context, context.rootId("progress"));

	public function build(context:BuildContext):RenderNode return context.mountComponent(this);

	function buildControl(context:BuildContext, nodeId:haxeon.ui.core.WidgetId):RenderNode {
		var computed = context.styleResolver.resolve(context.styleTarget(nodeId, "progress-bar", key, key, null,
			["progress-bar"]),
			context.inheritedStyle,
			context.theme.styles,
			context.styleSheet,
			style,
			context.environment);
		var node = context.createNode(nodeId, LayoutVisualKind.Custom, computed.toLayoutStyle());
		node.setStyleIdentity("progress-bar", key, key, null, ["progress-bar"]);
		node.states = context.interactionStates.peek(nodeId);
		node.computedStyle = computed;
		var indeterminate = mode == ProgressMode.Indeterminate;
		var semantics = new Semantics(AccessibilityRole.ProgressBar,
			label,
			indeterminate ? "Indeterminate" : Std.string(value));
		semantics.states = indeterminate ? AccessibilityState.Busy : AccessibilityState.ReadOnly;
		if (!indeterminate) {
			semantics.numericValue = value;
			semantics.numericMinimum = minimum;
			semantics.numericMaximum = maximum;
		}
		node.semantics = semantics;
		var fraction = (value - minimum) / (maximum - minimum);
		var stored:State<ProgressPainter> = context.resourceState(node.id,
			function() return new ProgressPainter(context.animations, fraction),
			function(painter:ProgressPainter) painter.dispose());
		var painter:ProgressPainter = cast stored.value;
		painter.configure(mode, fraction, animationDuration, context.environment.reducedMotion);
		node.onPaint(function(canvas, geometry) {
			var liveStyle:haxeon.ui.style.ComputedStyle = cast node.computedStyle;
			painter.paint(canvas,
				geometry,
				liveStyle.getColor(StyleProperty.ProgressTrackColor),
				liveStyle.getColor(StyleProperty.ProgressFillColor));
		});
		return node;
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(200.0);
		result.height = LayoutAxis.fixed(8.0);
		result.radiusTopLeft = result.radiusTopRight = 4.0;
		result.radiusBottomLeft = result.radiusBottomRight = 4.0;
		return result;
	}

	static inline function clamp(value:Float,
			minimum:Float, maximum:Float):Float return value < minimum ? minimum : value > maximum ? maximum : value;

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;
}

/** Visual and semantic behavior of a progress indicator. */
enum ProgressMode implements Hashable {
	/** The bar fills to the share of the work done. */
	Determinate;

	/** An animated bar for work whose amount is unknown; with reduced motion it holds still. */
	Indeterminate;
}

/** Retained animation state and drawing for determinate and indeterminate progress. */
internal class ProgressPainter implements Disposable {
	final scheduler:AnimationScheduler;
	final tween:AnimationController;
	final loop:LoopAnimation;
	final loopToken:Animation;
	var loopRegistration:Null<AnimationHandle>;
	var target:Float;
	var mode:ProgressMode;
	var reducedMotion:Bool;

	public function new(scheduler:AnimationScheduler, fraction:Float) {
		this.scheduler = scheduler;
		target = clamp(fraction);
		tween = new AnimationController(scheduler);
		tween.play(target, target, 0.0);
		loop = new LoopAnimation(0.85);
		loopToken = loop;
		loopRegistration = null;
		mode = ProgressMode.Determinate;
		reducedMotion = false;
	}

	public function configure(nextMode:ProgressMode, fraction:Float, duration:Float,
			reduceMotion:Bool):Void {
		var previousMode = mode;
		mode = nextMode;
		reducedMotion = reduceMotion;
		if (mode == ProgressMode.Indeterminate) {
			tween.stop();
			if (reducedMotion)
				stopLoop();
			else if (loopRegistration == null || !loopRegistration.active)
				loopRegistration = scheduler.track(loopToken);
			return;
		}
		stopLoop();
		var next = clamp(fraction);
		if (reduceMotion) {
			target = next;
			if (tween.value != next)
				tween.play(next, next, 0.0);
			return;
		}
		if (next == target && previousMode == ProgressMode.Determinate)
			return;
		target = next;
		if (duration <= 0.0)
			tween.play(next, next, 0.0);
		else
			tween.play(tween.value, next, duration, Easing.EaseOut);
	}

	public function paint(canvas:Canvas, geometry:ResolvedLayoutItem,
			track:Color, fill:Color):Void {
		canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), track);
		if (mode == ProgressMode.Determinate) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width * tween.value,
				geometry.height), fill);
			return;
		}
		var segment = geometry.width * 0.32;
		var start = reducedMotion
			? (geometry.width - segment) * 0.5 : loop.phase * (geometry.width + segment) - segment;
		var left = Math.max(0.0, start);
		var right = Math.min(geometry.width, start + segment);
		canvas.fillRectIfPositive(new Rect(left, 0.0, right - left, geometry.height), fill);
	}

	public function dispose():Void {
		tween.stop();
		stopLoop();
	}

	function stopLoop():Void {
		if (loopRegistration != null)
			loopRegistration.cancel();
		loopRegistration = null;
	}

	static inline function clamp(value:Float):Float
		return value < 0.0 ? 0.0 : value > 1.0 ? 1.0 : value;
}
