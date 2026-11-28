package haxeon.ui.widgets.scroll;


import haxeon.ui.widgets.scroll.ScrollView;
/**
 * Haxe-owned scroll offsets and resolved viewport/content metrics. Its smooth scrolling frames need no rebuild of their own: each
 * offset change goes to the bound callback, which moves content in place or asks for a rebuild itself.
 */
class ScrollController implements haxeon.ui.animation.Animation.RetainedAnimation {
	/** How long a smooth scroll takes, in seconds. */
	public var animationDuration(default, null):Float = 0.12;

	/** Whether scrolls are smoothed. */
	public var animated(default, null):Bool = false;
	var targetX:Float;
	var targetY:Float;
	final binding:ScrollControllerBindingState = new ScrollControllerBindingState();

	/** How far the content is scrolled left, in logical pixels. */
	public var offsetX(default, null):Float;

	/** How far the content is scrolled up, in logical pixels. */
	public var offsetY(default, null):Float;

	/** The viewport's width, as the last layout found it. */
	public var viewportWidth(default, null):Float;

	/** The viewport's height, as the last layout found it. */
	public var viewportHeight(default, null):Float;

	/** The content's width, as the last layout found it. */
	public var contentWidth(default, null):Float;

	/** The content's height, as the last layout found it. */
	public var contentHeight(default, null):Float;

	/** Whether a layout has measured the viewport and content yet. */
	public var hasMetrics(default, null):Bool;
	/** Fling decay: velocity is multiplied by this much per second, so about 2 s bring 4000 px/s to rest. */
	static inline var FlingFriction:Float = 0.135;
	/** A fling slower than this (px/s) is not started, and one that decays below it stops. */
	static inline var FlingMinVelocity:Float = 30.0;
	var flingX:Float = 0.0;
	var flingY:Float = 0.0;
	/** True while momentum from `fling` is still moving the content. */
	public var isFlinging(get, never):Bool;
	inline function get_isFlinging():Bool
		return flingX != 0.0 || flingY != 0.0;

	/** A scroll position starting at (`offsetX`, `offsetY`). */
	public function new(offsetX:Float = 0.0, offsetY:Float = 0.0) {
		if (!finiteNonNegative(offsetX) || !finiteNonNegative(offsetY))
			throw "Scroll offsets must be finite and non-negative";
		this.offsetX = offsetX;
		this.offsetY = offsetY;
		targetX = offsetX;
		targetY = offsetY;
		viewportWidth = 0.0;
		viewportHeight = 0.0;
		contentWidth = 0.0;
		contentHeight = 0.0;
		hasMetrics = false;
	}

	/** The largest horizontal offset: the content's overflow. */
	public var maxScrollX(get, never):Float;
	inline function get_maxScrollX():Float
		return Math.max(0.0, contentWidth - viewportWidth);

	/** The largest vertical offset: the content's overflow. */
	public var maxScrollY(get, never):Float;
	inline function get_maxScrollY():Float
		return Math.max(0.0, contentHeight - viewportHeight);

	/** Sets an absolute offset, clamped to the latest resolved content metrics. */
	public function jumpTo(x:Float, y:Float):Bool {
		if (!Math.isFinite(x) || !Math.isFinite(y))
			throw "Scroll offsets must be finite";
		cancelAnimation();
		var nextX = clampX(x);
		var nextY = clampY(y);
		targetX = nextX;
		targetY = nextY;
		if (nextX == offsetX && nextY == offsetY)
			return false;
		offsetX = nextX;
		offsetY = nextY;
		notifyChanged();
		return true;
	}

	/**
	 * Scrolls `start` to `end` of the content along an axis into view when layout next settles the offset, against the
	 * viewport it has then: to its start when it does not fit or lies before, else to its end when it lies after.
	 */
	public function revealRange(vertical:Bool, start:Float, end:Float):Void {
		revealKind = 1;
		revealVertical = vertical;
		revealStart = start;
		revealEnd = end;
	}

	/** Scrolls the content's node whose layout ID is `id` into view along an axis when layout next settles the offset. */
	public function revealNode(vertical:Bool, id:Int):Void {
		revealKind = 2;
		revealVertical = vertical;
		revealId = id;
	}

	var revealKind:Int = 0;
	var revealVertical:Bool = false;
	var revealStart:Float = 0.0;
	var revealEnd:Float = 0.0;
	var revealId:Int = 0;

	/** Applies a pending reveal, once layout has set the metrics; `content` finds a node's box in the content. */
	@:allow(haxeon.ui.widgets.scroll)
	function settleReveal(content:haxeon.ui.LayoutScroll.LayoutLocator):Void {
		var kind = revealKind;
		if (kind == 0) return;
		revealKind = 0;
		var vertical = revealVertical, start = revealStart, end = revealEnd;
		if (kind == 2) {
			if (!content.locate(revealId)) return;
			start = vertical ? content.y : content.x;
			end = start + (vertical ? content.height : content.width);
		}
		var viewport = vertical ? viewportHeight : viewportWidth;
		var current = vertical ? offsetY : offsetX, next = current;
		if (end - start > viewport || start < current) next = start;
		else if (end > current + viewport) next = end - viewport;
		if (next != current) vertical ? jumpTo(offsetX, next) : jumpTo(next, offsetY);
	}

	/**
	 * Starts momentum from a release velocity in px/s (positive scrolls toward larger offsets). The speed decays
	 * exponentially, and an axis stops at its edge. Any other offset change ends the fling.
	 */
	public function fling(velocityX:Float, velocityY:Float):Void {
		if (!Math.isFinite(velocityX) || !Math.isFinite(velocityY)) throw "Fling velocity must be finite";
		cancelAnimation();
		flingX = flingStart(velocityX, offsetX, maxScrollX);
		flingY = flingStart(velocityY, offsetY, maxScrollY);
		if (isFlinging && binding.scheduler != null) binding.scheduler.track(this);
	}

	/** Ends momentum where the content is now. */
	public function stopFling():Void {
		flingX = 0.0;
		flingY = 0.0;
	}

	/** The velocity an axis starts with: none when it is too slow, has no room to scroll, or already sits at the edge it heads for. */
	function flingStart(velocity:Float, offset:Float, maxScroll:Float):Float {
		if (Math.abs(velocity) < FlingMinVelocity) return 0.0;
		if (hasMetrics && maxScroll <= 0.0) return 0.0;
		if (velocity < 0.0 && offset <= 0.0) return 0.0;
		if (velocity > 0.0 && hasMetrics && offset >= maxScroll) return 0.0;
		return velocity;
	}

	/** Moves the content by this frame's share of the fling; returns whether momentum remains. */
	function advanceFling(deltaSeconds:Float):Bool {
		if (!isFlinging || deltaSeconds <= 0.0) return isFlinging;
		var decay = Math.pow(FlingFriction, deltaSeconds);
		// The distance covered while v decays exponentially: v * (1 - decay) / -ln(friction).
		var travel = (1.0 - decay) / -Math.log(FlingFriction);
		var nextX = clampX(offsetX + flingX * travel);
		var nextY = clampY(offsetY + flingY * travel);
		if (nextX == offsetX || (flingX < 0.0 && nextX <= 0.0)
			|| (flingX > 0.0 && hasMetrics && nextX >= maxScrollX)) flingX = 0.0;
		if (nextY == offsetY || (flingY < 0.0 && nextY <= 0.0)
			|| (flingY > 0.0 && hasMetrics && nextY >= maxScrollY)) flingY = 0.0;
		flingX *= decay;
		flingY *= decay;
		if (Math.abs(flingX) < FlingMinVelocity) flingX = 0.0;
		if (Math.abs(flingY) < FlingMinVelocity) flingY = 0.0;
		targetX = nextX;
		targetY = nextY;
		if (nextX != offsetX || nextY != offsetY) {
			offsetX = nextX;
			offsetY = nextY;
			notifyChanged();
		}
		return isFlinging;
	}

	/** Enables time-based exponential movement; jumpTo always remains immediate. */
	public function configureAnimation(enabled:Bool, duration:Float = 0.12):Void {
		if (!Math.isFinite(duration) || duration < 0) throw "Scroll duration must be finite and non-negative";
		animated = enabled;
		animationDuration = duration;
		if (!enabled || duration == 0) jumpTo(targetX, targetY);
	}

	/** Queues logical-pixel movement. Reversals discard the previous pending direction. */
	public function scrollBy(x:Float, y:Float):Bool {
		if (!Math.isFinite(x) || !Math.isFinite(y)) throw "Scroll movement must be finite";
		if (!animated || animationDuration == 0) return jumpTo(offsetX + x, offsetY + y);
		var nextX = clampX((x * (targetX - offsetX) < 0 ? offsetX : targetX) + x);
		var nextY = clampY((y * (targetY - offsetY) < 0 ? offsetY : targetY) + y);
		if (nextX == targetX && nextY == targetY) return false;
		targetX = nextX;
		targetY = nextY;
		if (binding.scheduler != null) binding.scheduler.track(this);
		notifyChanged();
		return true;
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!Math.isFinite(deltaSeconds) || deltaSeconds < 0) throw "Scroll time must be finite and non-negative";
		var flinging = advanceFling(deltaSeconds);
		if (deltaSeconds == 0) return flinging || offsetX != targetX || offsetY != targetY;
		var remaining = animationDuration == 0 ? 0 : Math.pow(0.01, deltaSeconds / animationDuration);
		var nextX = targetX + (offsetX - targetX) * remaining;
		var nextY = targetY + (offsetY - targetY) * remaining;
		if (Math.abs(nextX - targetX) < 0.5) nextX = targetX;
		if (Math.abs(nextY - targetY) < 0.5) nextY = targetY;
		if (nextX != offsetX || nextY != offsetY) {
			offsetX = nextX;
			offsetY = nextY;
			notifyChanged();
		}
		return flinging || offsetX != targetX || offsetY != targetY;
	}

	/** Stops a smooth scroll or a fling where it is. */
	public function cancelAnimation():Void {
		stopFling();
		if (binding.scheduler != null) binding.scheduler.remove(this);
		targetX = offsetX;
		targetY = offsetY;
	}

	inline function clampX(value:Float):Float return Math.max(0, hasMetrics ? Math.min(value, maxScrollX) : value);
	inline function clampY(value:Float):Float return Math.max(0, hasMetrics ? Math.min(value, maxScrollY) : value);

	@:allow(haxeon.ui.widgets.scroll.ScrollBinding)
	function bind(callback:ScrollController->Void, ?clock:haxeon.ui.animation.AnimationScheduler,
			?owner:ScrollBinding):Void {
		if (binding.scheduler != null && binding.scheduler != clock) binding.scheduler.remove(this);
		binding.changed = callback;
		binding.scheduler = clock;
		binding.owner = owner;
		if (binding.scheduler != null
			&& (offsetX != targetX || offsetY != targetY || isFlinging)) binding.scheduler.track(this);
	}

	@:allow(haxeon.ui.widgets.scroll.ScrollBinding)
	function unbind(owner:ScrollBinding):Void {
		if (binding.owner != owner) return;
		cancelAnimation();
		binding.changed = null;
		binding.scheduler = null;
		binding.owner = null;
	}

	@:allow(haxeon.ui.widgets.collections.ListView)
	@:allow(haxeon.ui.widgets.collections.TreeView)
	@:allow(haxeon.ui.widgets.collections.VirtualGrid)
	@:allow(haxeon.ui.widgets.collections.VirtualList)
	/** Seeds known fixed viewport axes without making content metrics available or clamping initial offsets. */
	function seedViewport(viewportWidth:Float, viewportHeight:Float):Void {
		if (hasMetrics) return;
		if (viewportWidth > 0.0) this.viewportWidth = viewportWidth;
		if (viewportHeight > 0.0) this.viewportHeight = viewportHeight;
	}

	@:allow(haxeon.ui.widgets.scroll.ScrollView)
	@:allow(haxeon.ui.widgets.collections.TreeView)
	function updateMetrics(viewportWidth:Float, viewportHeight:Float,
			contentWidth:Float, contentHeight:Float):Void {
		if (!finiteNonNegative(viewportWidth) || !finiteNonNegative(viewportHeight) || !finiteNonNegative(contentWidth)
			|| !finiteNonNegative(contentHeight))
			throw "Scroll metrics must be finite and non-negative";
		this.viewportWidth = viewportWidth;
		this.viewportHeight = viewportHeight;
		this.contentWidth = contentWidth;
		this.contentHeight = contentHeight;
		hasMetrics = true;
		targetX = Math.min(targetX, maxScrollX);
		targetY = Math.min(targetY, maxScrollY);
		var nextX = Math.min(offsetX, maxScrollX);
		var nextY = Math.min(offsetY, maxScrollY);
		if (nextX != offsetX || nextY != offsetY) {
			offsetX = nextX;
			offsetY = nextY;
			notifyChanged();
		}
	}

	function notifyChanged():Void {
		var callback = binding.changed;
		if (callback != null)
			callback(this);
	}

	static function finiteNonNegative(value:Float):Bool
		return Math.isFinite(value) && value >= 0.0;
}

private class ScrollControllerBindingState {
	public var scheduler:Null<haxeon.ui.animation.AnimationScheduler>;
	public var owner:Null<ScrollBinding>;
	public var changed:Null<ScrollController->Void>;
	public function new() {}
}
