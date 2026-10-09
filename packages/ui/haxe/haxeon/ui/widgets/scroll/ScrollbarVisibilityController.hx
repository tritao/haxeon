package haxeon.ui.widgets.scroll;

import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;

/** Mount-owned scrollbar visibility, independent of scroll geometry and paint. */
class ScrollbarVisibilityController implements Animation {
	static inline var FadeInSeconds:Float = 0.3;
	static inline var IdleSeconds:Float = 0.5;
	static inline var FadeOutSeconds:Float = 0.2;

	public var opacity(default, null):Float = 0.0;
	public var viewportHovered(default, null):Bool = false;
	/** Track hover controls its stronger styling separately from pane hover. */
	public var hovered(default, null):Bool = false;
	public var dragging(default, null):Bool = false;
	public var focused(default, null):Bool = false;
	var policy:Int = ScrollbarVisibility.Auto;
	var reducedMotion:Bool = false;
	var available:Bool = false;
	var targetOpacity:Float = 0.0;
	var idleRemaining:Float = 0.0;
	var scheduler:Null<AnimationScheduler>;
	var changed:Null<Void->Void>;
	var source:Null<ScrollController>;

	public function new() {}

	public function attach(clock:AnimationScheduler, notify:Void->Void):Void {
		if (scheduler != null && scheduler != clock) scheduler.remove(this);
		scheduler = clock;
		changed = notify;
		updateAnimation();
	}

	public function bindSource(value:ScrollController):Void {
		if (source == value) return;
		source = value;
		setAvailable(false);
	}

	public function configure(value:Int, reduceMotion:Bool):Void {
		if (value < ScrollbarVisibility.Auto || value > ScrollbarVisibility.Hidden)
			throw "Invalid scrollbar visibility";
		if (policy == value && reducedMotion == reduceMotion) return;
		var previousPolicy = policy;
		policy = value;
		reducedMotion = reduceMotion;
		if (!available || policy == ScrollbarVisibility.Hidden) hide();
		else if (policy == ScrollbarVisibility.Always) showAlways();
		else if (policy == ScrollbarVisibility.Always && available) showAlways();
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

	public function setAvailable(value:Bool):Void {
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
		if (opacity == previousOpacity && changed != null) changed();
	}

	function held():Bool return viewportHovered || hovered || dragging || focused;

	function animating():Bool {
		return available && policy == ScrollbarVisibility.Auto &&
			(opacity != targetOpacity || (!held() && targetOpacity > 0));
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
		if (changed != null) changed();
	}

	public function dispose():Void {
		if (scheduler != null) scheduler.remove(this);
		scheduler = null;
		changed = null;
		source = null;
	}
}
