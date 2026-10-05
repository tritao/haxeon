package haxeon.ui.widgets.scroll;

import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;

/** Mount-owned interaction and idle fade, independent of scroll geometry. */
class ScrollbarVisibilityController implements Animation {
	public var opacity(default, null):Float = 0.0;
	var policy:Int = ScrollbarVisibility.Auto;
	var reducedMotion:Bool = false;
	var available:Bool = false;
	var hovered:Bool = false;
	var dragging:Bool = false;
	var focused:Bool = false;
	var remaining:Float = 0.0;
	var scheduler:Null<AnimationScheduler>;
	var changed:Null<Void->Void>;
	var source:Null<ScrollController>;

	public function new() {}

	public function attach(clock:AnimationScheduler, notify:Void->Void):Void {
		if (scheduler != null && scheduler != clock) scheduler.remove(this);
		scheduler = clock; changed = notify;
	}

	public function bindSource(value:ScrollController):Void {
		if (source == value) return;
		source = value;
		if (scheduler != null) scheduler.remove(this);
		available = false; remaining = 0;
		setOpacity(0);
	}

	public function configure(value:Int, reduceMotion:Bool):Void {
		if (value < ScrollbarVisibility.Auto || value > ScrollbarVisibility.Hidden) throw "Invalid scrollbar visibility";
		if (policy == value && reducedMotion == reduceMotion) return;
		policy = value; reducedMotion = reduceMotion;
		if (scheduler != null) scheduler.remove(this);
		if (!available || policy == ScrollbarVisibility.Hidden) setOpacity(0);
		else if (policy == ScrollbarVisibility.Always || held()) setOpacity(1);
		else if (opacity > 0) schedule();
	}

	public function setAvailable(value:Bool):Void {
		available = value;
		if (!available) {
			hovered = false; dragging = false; focused = false;
			if (scheduler != null) scheduler.remove(this);
			setOpacity(0);
		} else if (policy == ScrollbarVisibility.Always || (policy == ScrollbarVisibility.Auto && held())) setOpacity(1);
	}

	public function setHovered(value:Bool):Void { hovered = value; interactionChanged(); }
	public function setDragging(value:Bool):Void { dragging = value; interactionChanged(); }
	public function setFocused(value:Bool):Void { focused = value; interactionChanged(); }

	public function reveal():Void {
		if (!available || policy == ScrollbarVisibility.Hidden) return;
		setOpacity(1);
		if (held() || policy == ScrollbarVisibility.Always) {
			if (scheduler != null) scheduler.remove(this);
		} else schedule();
	}

	function interactionChanged():Void {
		if (held()) reveal();
		else if (available && policy == ScrollbarVisibility.Auto && opacity > 0) schedule();
	}

	function held():Bool return hovered || dragging || focused;
	function schedule():Void {
		remaining = 0.5 + (reducedMotion ? 0.0 : 0.2);
		if (scheduler != null) scheduler.track(this);
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!available || policy != ScrollbarVisibility.Auto || held()) return false;
		remaining = Math.max(0.0, remaining - deltaSeconds);
		setOpacity(reducedMotion ? (remaining > 0 ? 1.0 : 0.0) : Math.min(1.0, remaining / 0.2));
		return remaining > 0;
	}

	function setOpacity(value:Float):Void {
		if (value == opacity) return;
		opacity = value;
		if (changed != null) changed();
	}

	public function dispose():Void {
		if (scheduler != null) scheduler.remove(this);
		scheduler = null; changed = null; source = null;
	}
}
