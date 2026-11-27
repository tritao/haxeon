package haxeon.reactive;

/**
 * The tracking `ReactiveRuntime.enterTracking` replaced, for `leaveTracking` to restore: a value, so entering and leaving
 * allocate no callback or stack record.
 */
struct TrackingFrame {
	/** The collector that was recording before, or null. */
	public final previous:Null<ReactiveCollector>;

	/** Where the creation log's scope started before. */
	public final previousStart:Int;

	/** How many entries the creation log held before. */
	public final previousCount:Int;

	/** A frame restoring `previous` and the creation log's scope. */
	public function new(previous:Null<ReactiveCollector>, previousStart:Int, previousCount:Int) {
		this.previous = previous;
		this.previousStart = previousStart;
		this.previousCount = previousCount;
	}
}
