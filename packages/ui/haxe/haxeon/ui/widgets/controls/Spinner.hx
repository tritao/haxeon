package haxeon.ui.widgets.controls;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.Paint.SolidPaint;
import haxeon.ui.Path;
import haxeon.ui.PathBuilder;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;
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

/** Procedural visual used by Spinner. */
enum SpinnerKind implements Hashable {
	/** A rotating open arc. */
	Ring;
	/** Twelve dots with a moving highlight. */
	Dots;
	/** Twelve radial bars with a moving highlight. */
	Bars;
	/** Two expanding and fading circles. */
	Pulse;
}

/** Owns the reusable resources and command encoding for a procedural spinner. */
internal class SpinnerPainter implements Disposable {
	static inline var TwoPi:Float = 6.283185307179586;

	public var kind(default, null):SpinnerKind;
	final animation:SpinnerClock;
	final circle:Path;
	final arc:Path;
	final bar:Path;
	var paintResource:SolidPaint;

	final animationToken:Animation;
	final scheduler:AnimationScheduler;
	var registration:Null<AnimationHandle>;
	var color:Color;

	public function new(scheduler:AnimationScheduler, color:Color, speed:Float,
			kind:SpinnerKind = SpinnerKind.Ring) {
		if (scheduler == null)
			throw "Spinner painter requires an animation scheduler";
		if (!finite(speed) || speed <= 0.0)
			throw "Spinner speed must be finite and positive";
		this.scheduler = scheduler;
		this.color = color;
		this.kind = kind;
		animation = new SpinnerClock(speed);
		animationToken = animation;
		registration = null;

		var madeCircle:Path = null;
		var madeArc:Path = null;
		var madeBar:Path = null;
		var madePaint:SolidPaint = null;
		try {
			madeCircle = createCircle();
			madeArc = createArc();
			madeBar = createBar();
			madePaint = SolidPaint.create(color);
		} catch (error:Dynamic) {
			if (madePaint != null)
				madePaint.dispose();
			if (madeBar != null)
				madeBar.dispose();
			if (madeArc != null)
				madeArc.dispose();
			if (madeCircle != null)
				madeCircle.dispose();
			throw error;
		}
		circle = cast madeCircle;
		arc = cast madeArc;
		bar = cast madeBar;
		paintResource = cast madePaint;
	}

	/** Updates paint, speed, and kind while retaining the resource identity. */
	public function configure(nextKind:SpinnerKind, nextColor:Color, speed:Float):Void {
		if (nextColor == null)
			throw "Spinner painter requires a color";
		if (!finite(speed) || speed <= 0.0)
			throw "Spinner speed must be finite and positive";
		kind = nextKind;
		animation.speed = speed;
		if (!sameColor(color, nextColor)) {
			var nextPaint = SolidPaint.create(nextColor);
			var previous = paintResource;
			paintResource = nextPaint;
			color = nextColor;
			previous.dispose();
		}
	}

	/** Starts or pauses scheduling without changing the current animation phase. */
	public function setRunning(running:Bool):Void {
		if (running) {
			if (registration == null || !registration.active)
				registration = scheduler.track(animationToken);
		} else if (registration != null) {
			registration.cancel();
			registration = null;
		}
	}

	/** Encodes the current spinner frame into a canvas command stream. */
	public function paintFrame(canvas:Canvas, geometry:ResolvedLayoutItem):Void {
		if (canvas == null || geometry == null)
			throw "Spinner painting requires a canvas and geometry";
		var size = Math.min(geometry.width, geometry.height);
		if (size <= 0.0)
			return;

		canvas.withState(function(target) {
			target.translate(geometry.width * 0.5, geometry.height * 0.5);
			target.scale(size * 0.42, size * 0.42);
			switch (kind) {
				case SpinnerKind.Ring:
					target.rotate(animation.phase * TwoPi);
					target.stroke(arc, paintResource, 0.16, LineCap.Round, LineJoin.Round);
				case SpinnerKind.Dots:
					paintDots(target);
				case SpinnerKind.Bars:
					paintBars(target);
				case SpinnerKind.Pulse:
					paintPulse(target);
			}
		});
	}

	/** Releases the scheduler registration and all native drawing resources. */
	public function dispose():Void {
		if (registration != null)
			registration.cancel();
		registration = null;
		paintResource.dispose();
		bar.dispose();
		arc.dispose();
		circle.dispose();
	}

	function paintDots(canvas:Canvas):Void {
		for (index in 0...12) {
			var normalized = index / 12.0;
			var distance = normalized - animation.phase;
			if (distance < 0.0)
				distance += 1.0;
			var alpha = 0.18 + 0.82 * (1.0 - distance);
			var angle = normalized * TwoPi - Math.PI * 0.5;
			canvas.withState(function(dot) {
				dot.translate(Math.cos(angle) * 0.74, Math.sin(angle) * 0.74);
				dot.scale(0.11, 0.11);
				dot.setAlpha(alpha);
				dot.fill(circle, paintResource);
			});
		}
	}

	function paintBars(canvas:Canvas):Void {
		for (index in 0...12) {
			var normalized = index / 12.0;
			var distance = normalized - animation.phase;
			if (distance < 0.0)
				distance += 1.0;
			var alpha = 0.18 + 0.82 * (1.0 - distance);
			var angle = normalized * TwoPi;
			canvas.withState(function(barCanvas) {
				barCanvas.rotate(angle);
				barCanvas.setAlpha(alpha);
				barCanvas.fill(bar, paintResource);
			});
		}
	}

	function paintPulse(canvas:Canvas):Void {
		paintPulseCircle(canvas, animation.phase);
		var delayed = animation.phase + 0.5;
		if (delayed >= 1.0)
			delayed -= 1.0;
		paintPulseCircle(canvas, delayed);
	}

	function paintPulseCircle(canvas:Canvas, progress:Float):Void {
		canvas.withState(function(circleCanvas) {
			circleCanvas.scale(0.16 + progress * 0.60, 0.16 + progress * 0.60);
			circleCanvas.setAlpha(0.68 * (1.0 - progress));
			circleCanvas.fill(circle, paintResource);
		});
	}

	static function createCircle():Path {
		var k = 0.5522847498;
		return new PathBuilder().moveTo(1.0, 0.0)
			.cubicTo(1.0, k, k, 1.0, 0.0, 1.0)
			.cubicTo(-k, 1.0, -1.0, k, -1.0, 0.0)
			.cubicTo(-1.0, -k, -k, -1.0, 0.0, -1.0)
			.cubicTo(k, -1.0, 1.0, -k, 1.0, 0.0)
			.close().build();
	}

	static function createArc():Path {
		var k = 0.5522847498;
		return new PathBuilder().moveTo(0.0, -1.0)
			.cubicTo(k, -1.0, 1.0, -k, 1.0, 0.0)
			.cubicTo(1.0, k, k, 1.0, 0.0, 1.0)
			.cubicTo(-k, 1.0, -1.0, k, -1.0, 0.0).build();
	}

	static function createBar():Path {
		return new PathBuilder().moveTo(-0.11, -0.94).lineTo(0.11, -0.94)
			.lineTo(0.11, -0.58).lineTo(-0.11, -0.58).close().build();
	}

	static function sameColor(left:Color, right:Color):Bool
		return haxeon.Equality.equals(left, right);

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

/**
 * Spinner phase advanced in fixed steps. Between steps nothing on screen changes, so the host sleeps until the next step
 * instead of drawing every display refresh, and a step only repaints the spinner's own custom paint (it has no paint cache
 * key), so its frames rebuild nothing. An editor waiting on a long background job therefore idles near zero CPU.
 */
@:noCompletion
internal class SpinnerClock implements DelayedAnimation implements RetainedAnimation {
	/** Visible steps per second; smooth enough for an indeterminate indicator. */
	public static inline var StepsPerSecond:Float = 15.0;
	/** A wake this close to a step boundary takes the step, so timer jitter does not cost an extra wake. */
	static inline var Tolerance:Float = 0.002;

	public var phase(default, null):Float = 0.0;
	public var speed:Float;
	/** Steps taken; each one is a visible change. */
	public var steps(default, null):Int = 0;
	/** Seconds since the last step; slightly negative when a step was taken a little early. */
	var pending:Float = 0.0;

	public function new(speed:Float) {
		if (!(speed == speed && speed - speed == 0.0) || speed <= 0.0)
			throw "Spinner speed must be finite and positive";
		this.speed = speed;
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!(deltaSeconds == deltaSeconds && deltaSeconds - deltaSeconds == 0.0) || deltaSeconds < 0.0)
			throw "Spinner time must be finite and non-negative";
		pending += deltaSeconds;
		var step = 1.0 / StepsPerSecond;
		if (pending + Tolerance < step)
			return true;
		var count = Std.int((pending + Tolerance) / step);
		pending -= count * step;
		phase += count * step * speed;
		phase -= Std.int(phase);
		steps += count;
		return true;
	}

	public function delaySeconds():Float {
		var remaining = 1.0 / StepsPerSecond - pending;
		// Never report zero: that would ask the host for frames every refresh instead of a wake.
		return remaining > 0.001 ? remaining : 0.001;
	}
}
