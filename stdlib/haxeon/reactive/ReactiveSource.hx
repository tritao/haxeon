package haxeon.reactive;

/** A versioned source with intrusive links to the computations that read it. */
class ReactiveSource {
	#if wasm
	static var nextId:haxe.Int64 = haxe.Int64.ofInt(0);
	#end
	public final reactiveId:haxe.Int64;
	final reservedIds:Int;
	public var version(default, null):Int = 0;
	var observerHead:ReactiveEdge;

	public function new(reservedIds:Int = 1) {
		if (reservedIds < 1)
			throw 'A reactive source must reserve at least one dependency id, got $reservedIds';
		#if wasm
		var count = haxe.Int64.ofInt(reservedIds);
		var max = haxe.Int64.make(0x7fffffff, -1);
		if (nextId > max - count) nextId = haxe.Int64.ofInt(0);
		reactiveId = nextId + haxe.Int64.ofInt(1);
		nextId = nextId + count;
		#else
		reactiveId = reserveReactiveIds(reservedIds);
		#end
		this.reservedIds = reservedIds;
	}

	/** Identity used by the reader's reusable edge table. Observable objects reserve one ID per field bit. */
	public function dependencyId(fieldBit:Int):haxe.Int64 {
		if (fieldBit < 0 || fieldBit >= reservedIds)
			throw 'Reactive dependency bit $fieldBit is outside the reserved range of $reservedIds';
		return reactiveId;
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

#if !wasm
@:hlNative("haxeon_runtime", "__reactive_reserve_ids")
extern function reserveReactiveIds(count:Int):haxe.Int64;
#end
