package haxeon.ui.widgets.scroll;

/**
 * Haxe-owned scroll offsets and resolved viewport/content metrics. Its smooth scrolling frames need no rebuild of their own: each
 * offset change goes to the bound callback, which moves content in place or asks for a rebuild itself.
 */
class ScrollController implements haxeon.ui.animation.RetainedAnimation {
	public var animationDuration(default, null):Float = 0.12;
	public var animated(default, null):Bool = false;
	var targetX:Float;
	var targetY:Float;
	var scheduler:Null<haxeon.ui.animation.AnimationScheduler>;
	var bindingOwner:Null<ScrollBinding>;
	public var offsetX(default, null):Float;
	public var offsetY(default, null):Float;
	public var viewportWidth(default, null):Float;
	public var viewportHeight(default, null):Float;
	public var contentWidth(default, null):Float;
	public var contentHeight(default, null):Float;
	public var hasMetrics(default, null):Bool;
	/** Changes to scroll offsets, targets or resolved viewport/content metrics. */
	public var revision(default, null):Int = 0;
	var changed:ScrollController->Void;

	public function new(offsetX:Float = 0.0, offsetY:Float = 0.0) {
		if (!finiteNonNegative(offsetX) || !finiteNonNegative(offsetY))
			throw "Scroll offsets must be finite and non-negative";
		this.offsetX = offsetX;
		this.offsetY = offsetY;
		targetX = offsetX; targetY = offsetY;
		viewportWidth = 0.0;
		viewportHeight = 0.0;
		contentWidth = 0.0;
		contentHeight = 0.0;
		hasMetrics = false;
		changed = null;
	}

	public var maxScrollX(get, never):Float;
	inline function get_maxScrollX():Float
		return Math.max(0.0, contentWidth - viewportWidth);

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
		targetX = nextX; targetY = nextY;
		if (nextX == offsetX && nextY == offsetY)
			return false;
		offsetX = nextX;
		offsetY = nextY;
		notifyChanged();
		return true;
	}

	/** Enables time-based exponential movement; jumpTo always remains immediate. */
	public function configureAnimation(enabled:Bool, duration:Float = 0.12):Void {
		if (!Math.isFinite(duration) || duration < 0) throw "Scroll duration must be finite and non-negative";
		animated = enabled; animationDuration = duration;
		if (!enabled || duration == 0) jumpTo(targetX, targetY);
	}

	/** Queues logical-pixel movement. Reversals discard the previous pending direction. */
	public function scrollBy(x:Float, y:Float):Bool {
		if (!Math.isFinite(x) || !Math.isFinite(y)) throw "Scroll movement must be finite";
		if (!animated || animationDuration == 0) return jumpTo(offsetX + x, offsetY + y);
		var nextX = clampX((x * (targetX - offsetX) < 0 ? offsetX : targetX) + x);
		var nextY = clampY((y * (targetY - offsetY) < 0 ? offsetY : targetY) + y);
		if (nextX == targetX && nextY == targetY) return false;
		targetX = nextX; targetY = nextY;
		if (scheduler != null) scheduler.track(this);
		notifyChanged();
		return true;
	}

	public function advance(deltaSeconds:Float):Bool {
		if (!Math.isFinite(deltaSeconds) || deltaSeconds < 0) throw "Scroll time must be finite and non-negative";
		if (deltaSeconds == 0) return offsetX != targetX || offsetY != targetY;
		var remaining = animationDuration == 0 ? 0 : Math.pow(0.01, deltaSeconds / animationDuration);
		var nextX = targetX + (offsetX - targetX) * remaining;
		var nextY = targetY + (offsetY - targetY) * remaining;
		if (Math.abs(nextX - targetX) < 0.5) nextX = targetX;
		if (Math.abs(nextY - targetY) < 0.5) nextY = targetY;
		if (nextX != offsetX || nextY != offsetY) {
			offsetX = nextX; offsetY = nextY; notifyChanged();
		}
		return offsetX != targetX || offsetY != targetY;
	}

	public function cancelAnimation():Void {
		if (scheduler != null) scheduler.remove(this);
		targetX = offsetX; targetY = offsetY;
	}

	inline function clampX(value:Float):Float return Math.max(0, hasMetrics ? Math.min(value, maxScrollX) : value);
	inline function clampY(value:Float):Float return Math.max(0, hasMetrics ? Math.min(value, maxScrollY) : value);

	@:allow(haxeon.ui.widgets.scroll.ScrollBinding)
	function bind(callback:ScrollController->Void, ?clock:haxeon.ui.animation.AnimationScheduler, ?owner:ScrollBinding):Void {
		if (scheduler != null && scheduler != clock) scheduler.remove(this);
		changed = callback; scheduler = clock; bindingOwner = owner;
		if (scheduler != null && (offsetX != targetX || offsetY != targetY)) scheduler.track(this);
	}

	@:allow(haxeon.ui.widgets.scroll.ScrollBinding)
	function unbind(owner:ScrollBinding):Void {
		if (bindingOwner != owner) return;
		cancelAnimation(); changed = null; scheduler = null; bindingOwner = null;
	}

	@:allow(haxeon.ui.widgets.scroll.ScrollView)
	@:allow(haxeon.ui.widgets.collections.TreeView)
	function updateMetrics(viewportWidth:Float, viewportHeight:Float,
			contentWidth:Float, contentHeight:Float):Void {
		if (!finiteNonNegative(viewportWidth) || !finiteNonNegative(viewportHeight) ||
			!finiteNonNegative(contentWidth) || !finiteNonNegative(contentHeight))
			throw "Scroll metrics must be finite and non-negative";
		if (!hasMetrics || this.viewportWidth != viewportWidth || this.viewportHeight != viewportHeight ||
			this.contentWidth != contentWidth || this.contentHeight != contentHeight) revision++;
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
		revision++;
		if (changed != null)
			changed(this);
	}

	static function finiteNonNegative(value:Float):Bool
		return Math.isFinite(value) && value >= 0.0;
}
