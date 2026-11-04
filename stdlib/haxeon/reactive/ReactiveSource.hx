package haxeon.reactive;

/** A versioned source with intrusive links to the computations that read it. */
class ReactiveSource {
	public var version(default, null):Int = 0;
	var observerHead:ReactiveEdge;

	public function new() {}

	/** Ordinary reactive sources have one dependency; Observable sources have field bits. */
	@:allow(haxeon.reactive.ReactiveDependencySet)
	function checkFieldBit(fieldBit:Int):Void {
		if (fieldBit != 0) throw 'Reactive dependency bit $fieldBit is outside the source';
	}

	/** Find an existing reader without a global source ID or an allocation. */
	@:allow(haxeon.reactive.ReactiveDependencySet)
	function findReader(reader:ReactiveDependencySet, fieldBit:Int):Null<ReactiveEdge> {
		var edge = observerHead;
		while (edge != null) {
			if (haxeon.Identity.same(edge.reader, reader) && edge.fieldBit == fieldBit) return edge;
			edge = edge.sourceNext;
		}
		return null;
	}

	/** Version of the dependency represented by one edge. Ordinary sources have a single version. */
	public function versionAt(fieldBit:Int):Int return version;

	@:allow(haxeon.reactive.ReactiveRuntime)
	function recordRead():Void
		ReactiveRuntime.track(this);

	@:allow(haxeon.reactive.ReactiveDependencySet)
	function subscribe(edge:ReactiveEdge):Void {
		edge.sourcePrevious = null;
		edge.sourceNext = observerHead;
		if (observerHead != null) observerHead.sourcePrevious = edge;
		observerHead = edge;
	}

	@:allow(haxeon.reactive.ReactiveDependencySet)
	function unsubscribe(edge:ReactiveEdge):Void {
		if (edge.sourcePrevious == null)
			observerHead = edge.sourceNext;
		else
			edge.sourcePrevious.sourceNext = edge.sourceNext;
		if (edge.sourceNext != null) edge.sourceNext.sourcePrevious = edge.sourcePrevious;
		edge.sourcePrevious = null;
		edge.sourceNext = null;
	}

	@:allow(haxeon.reactive.ReactiveDependencySet)
	@:allow(haxeon.reactive.Signal)
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

	/** Pushes invalidation only to readers of one field on a multi-field source. */
	public function invalidateFieldReaders(fieldBit:Int):Void {
		var edge = observerHead;
		while (edge != null) {
			var next = edge.sourceNext;
			if (edge.fieldBit == fieldBit) {
				// Observable field versions are represented by each subscribed edge. Marking
				// the edge stale needs no per-object version array or allocation on first write.
				edge.seenVersion = -1;
				edge.reader.markMaybeStale();
			}
			edge = next;
		}
	}

	public function hasFieldReaders(fieldBit:Int):Bool {
		var edge = observerHead;
		while (edge != null) {
			if (edge.fieldBit == fieldBit)
				return true;
			edge = edge.sourceNext;
		}
		return false;
	}
}
