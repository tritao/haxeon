package haxeon.ui.widgets.scroll;

import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;
import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;

import haxeon.ui.widgets.scroll.ScrollView;
/**
 * Mount-owned scrollbar visibility, independent of scroll geometry and paint. Its changes, at animation ticks and on
 * input, bump `changes`, which the scrollbar's own scope reads: a fade frame runs that scope again alone.
 */
internal class ScrollbarVisibilityController implements DelayedAnimation implements Disposable {
	static inline var FadeInSeconds:Float = 0.3;
	static inline var IdleSeconds:Float = 0.5;
	static inline var FadeOutSeconds:Float = 0.2;

	public var opacity(default, null):Float = 0.0;
	public var viewportHovered(default, null):Bool = false;
	/** Track hover controls its stronger styling separately from pane hover. */
	public var hovered(default, null):Bool = false;
	public var dragging(default, null):Bool = false;
	public var focused(default, null):Bool = false;
	var policy:ScrollbarVisibility = ScrollbarVisibility.Auto;
	var reducedMotion:Bool = false;
	var available:Bool = false;
	var targetOpacity:Float = 0.0;
	var idleRemaining:Float = 0.0;
	var scheduler:Null<AnimationScheduler>;
	/**
	 * Bumped when its opacity or the scrollbar's styling changes outside a build. A change made while the scroll view
	 * builds needs none: the scrollbar is built again in that same pass.
	 */
	public final changes:Signal<Int> = new Signal(0);
	var source:Null<ScrollController>;

	public function new() {}

	public function attach(clock:AnimationScheduler):Void {
		if (scheduler != null && scheduler != clock) scheduler.remove(this);
		scheduler = clock;
		updateAnimation();
	}

	function notifyChanged():Void {
		if (!ReactiveRuntime.isTracking()) changes.value = changes.value + 1;
	}

	public function bindSource(value:ScrollController):Void {
		if (source == value) return;
		source = value;
		// Set while building, not from layout: a new source starts with nothing known to scroll.
		applyAvailable(false);
	}

	public function configure(value:ScrollbarVisibility, reduceMotion:Bool):Void {
		if (policy == value && reducedMotion == reduceMotion) return;
		var previousPolicy = policy;
		policy = value;
		reducedMotion = reduceMotion;
		if (!available || policy == ScrollbarVisibility.Hidden) hide();
		else if (policy == ScrollbarVisibility.Always) showAlways();
		else if (held()) reveal();
		else {
			if (previousPolicy == ScrollbarVisibility.Always) {
				targetOpacity = 1.0;
				idleRemaining = IdleSeconds;
			}
			if (reducedMotion) setOpacity(targetOpacity);
			updateAnimation();
		}
	}

	/**
	 * Whether there is anything to scroll, which layout finds. A change that would show or hide the scrollbar at once is
	 * applied at the next animation tick, before the next build: that edits the scrollbar's nodes, which layout has
	 * placed for this frame. Any other change applies now.
	 */
	public function setAvailable(value:Bool):Void {
		var current = availablePending ? pendingAvailable : available;
		if (current == value) return;
		var clock = scheduler;
		if (clock == null || !changesOpacity(value)) {
			applyAvailable(value);
			return;
		}
		availablePending = true;
		pendingAvailable = value;
		clock.track(this);
	}

	function changesOpacity(available:Bool):Bool {
		if (!available) return opacity != 0.0;
		if (policy == ScrollbarVisibility.Always) return opacity != 1.0;
		return policy == ScrollbarVisibility.Auto && reducedMotion && held() && opacity != 1.0;
	}

	var availablePending:Bool = false;
	var pendingAvailable:Bool = false;

	function applyAvailable(value:Bool):Void {
		availablePending = false;
		if (available == value) return;
		available = value;
		if (!available) {
			// The pane can remain hovered while its content stops overflowing.
			// Retain that state so new overflow reveals without another pointer event.
			hovered = false;
			dragging = false;
			focused = false;
			hide();
		} else if (policy == ScrollbarVisibility.Always) showAlways();
		else if (held()) reveal();
	}

	public function setViewportHovered(value:Bool):Void {
		if (viewportHovered == value) return;
		viewportHovered = value;
		interactionChanged();
	}

	public function setHovered(value:Bool):Void {
		if (hovered == value) return;
		hovered = value;
		interactionChanged();
	}

	public function setDragging(value:Bool):Void {
		if (dragging == value) return;
		dragging = value;
		interactionChanged();
	}

	public function setFocused(value:Bool):Void {
		if (focused == value) return;
		focused = value;
		interactionChanged();
	}

	/** Reveals from the current opacity; repeated activity never restarts the fade. */
	public function reveal():Void {
		if (!available || policy == ScrollbarVisibility.Hidden) return;
		targetOpacity = 1.0;
		idleRemaining = IdleSeconds;
		if (reducedMotion || policy == ScrollbarVisibility.Always) setOpacity(1.0);
		updateAnimation();
	}

	function interactionChanged():Void {
		var previousOpacity = opacity;
		if (policy == ScrollbarVisibility.Always && available) showAlways();
		else if (held()) reveal();
		else {
			// Leaving the pane/track or releasing the final interaction starts
			// fading immediately; scroll-only activity retains its idle grace.
			idleRemaining = 0.0;
			targetOpacity = 0.0;
			if (reducedMotion) setOpacity(0.0);
			updateAnimation();
		}
		// Track styling can change independently of the visibility animation.
		if (opacity == previousOpacity) notifyChanged();
	}

	function held():Bool return viewportHovered || hovered || dragging || focused;

	function animating():Bool {
		if (availablePending) return true;
		return available && policy == ScrollbarVisibility.Auto
			&& (opacity != targetOpacity || (!held() && targetOpacity > 0));
	}

	/** The idle grace after a fade-in changes nothing on screen, so it needs a wake, not frames. */
	public function delaySeconds():Float {
		if (availablePending || !animating() || held() || targetOpacity <= 0.0 || opacity != 1.0) return 0.0;
		return idleRemaining;
	}

	function updateAnimation():Void {
		if (scheduler == null) return;
		if (animating()) scheduler.track(this);
		else scheduler.remove(this);
	}

	function hide():Void {
		targetOpacity = 0.0;
		idleRemaining = 0.0;
		setOpacity(0.0);
		updateAnimation();
	}

	function showAlways():Void {
		targetOpacity = 1.0;
		setOpacity(1.0);
		updateAnimation();
	}

	public function advance(deltaSeconds:Float):Bool {
		if (availablePending) applyAvailable(pendingAvailable);
		if (!available || policy != ScrollbarVisibility.Auto) return false;
		// Consume each phase in order so a long frame produces the same result
		// as several short frames. The idle delay starts after the fade-in ends.
		if (targetOpacity > 0 && opacity < 1.0) {
			var duration = (1.0 - opacity) * FadeInSeconds;
			var elapsed = Math.min(deltaSeconds, duration);
			setOpacity(elapsed >= duration ? 1.0 : opacity + elapsed / FadeInSeconds);
			deltaSeconds -= elapsed;
		}
		if (targetOpacity > 0 && opacity == 1.0 && !held()) {
			var elapsed = Math.min(deltaSeconds, idleRemaining);
			idleRemaining = Math.max(0.0, idleRemaining - elapsed);
			deltaSeconds -= elapsed;
			if (idleRemaining == 0.0) targetOpacity = 0.0;
		}
		if (targetOpacity == 0.0)
			setOpacity(reducedMotion ? 0.0 : Math.max(0.0, opacity - deltaSeconds / FadeOutSeconds));
		return animating();
	}

	function setOpacity(value:Float):Void {
		if (value == opacity) return;
		opacity = value;
		notifyChanged();
	}

	public function dispose():Void {
		if (scheduler != null) scheduler.remove(this);
		scheduler = null;
		source = null;
	}
}
