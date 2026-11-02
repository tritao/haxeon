package haxeon.ui.core;

/** A versioned source with intrusive links to the computations that read it. */
class ReactiveSource {
	static var nextId:Int = 0;
	public final reactiveId:Int;
	final reservedIds:Int;
	public var version(default, null):Int = 0;
	var observerHead:ReactiveEdge;

	public function new(reservedIds:Int = 1) {
		if (reservedIds < 1)
			throw 'A reactive source must reserve at least one dependency id, got $reservedIds';
		if (nextId > 0x7fffffff - reservedIds)
			nextId = 0;
		reactiveId = nextId + 1;
		nextId += reservedIds;
		this.reservedIds = reservedIds;
	}

	/** Identity used by the reader's reusable edge table. Observable objects reserve one ID per field bit. */
	public function dependencyId(fieldBit:Int):Int {
		if (fieldBit < 0 || fieldBit >= reservedIds)
			throw 'Reactive dependency bit $fieldBit is outside the reserved range of $reservedIds';
		return reactiveId;
	}

	/** Version of the dependency represented by one edge. Ordinary sources have a single version. */
	public function versionAt(fieldBit:Int):Int return version;

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

	/** Pushes invalidation only to readers of one field on a multi-field source. */
	public function invalidateFieldReaders(fieldBit:Int):Void {
		var edge = observerHead;
		while (edge != null) {
			var next = edge.sourceNext;
			if (edge.fieldBit == fieldBit)
				edge.reader.markMaybeStale();
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
