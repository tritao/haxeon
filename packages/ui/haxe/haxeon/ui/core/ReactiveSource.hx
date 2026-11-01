package haxeon.ui.core;

/** A versioned source with intrusive links to the computations that read it. */
class ReactiveSource {
	static var nextId:Int = 0;
	public final reactiveId:Int;
	public var version(default, null):Int = 0;
	var observerHead:ReactiveEdge;

	public function new() {
		nextId = nextId == 0x7fffffff ? 1 : nextId + 1;
		reactiveId = nextId;
	}

	@:allow(haxeon.ui.core.ReactiveRuntime)
	function recordRead():Void
		ReactiveRuntime.track(this);

	@:allow(haxeon.ui.core.ReactiveDependencySet)
	function subscribe(edge:ReactiveEdge):Void {
		edge.sourcePrevious = null;
		edge.sourceNext = observerHead;
		if (observerHead != null) observerHead.sourcePrevious = edge;
		observerHead = edge;
	}

	@:allow(haxeon.ui.core.ReactiveDependencySet)
	function unsubscribe(edge:ReactiveEdge):Void {
		if (edge.sourcePrevious == null)
			observerHead = edge.sourceNext;
		else
			edge.sourcePrevious.sourceNext = edge.sourceNext;
		if (edge.sourceNext != null) edge.sourceNext.sourcePrevious = edge.sourcePrevious;
		edge.sourcePrevious = null;
		edge.sourceNext = null;
	}

	@:allow(haxeon.ui.core.ReactiveDependencySet)
	@:allow(haxeon.ui.core.Signal)
	function bumpVersion():Void
		version = version == 0x7fffffff ? 1 : version + 1;

	/** Derived sources pull their inputs here before a reader compares versions. */
	public function ensureCurrent():Void {}

	/** Pushes a maybe-stale mark; readers pull versions before doing their work. */
	public function invalidateReaders():Void {
		var edge = observerHead;
		while (edge != null) {
			var next = edge.sourceNext;
			edge.reader.markMaybeStale();
			edge = next;
		}
	}
}
