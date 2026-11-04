package haxeon.reactive;

/** Reusable dependency edges for a derived value, effect or retained computation. */
class ReactiveDependencySet extends ReactiveSource implements ReactiveCollector {
	static inline var Clean:Int = 0;
	static inline var MaybeStale:Int = 1;
	static inline var Dirty:Int = 2;
	static inline var Failed:Int = 3;
	static inline var MaxStamp:Int = 0x7fffffff;

	public final captureOnly:Bool;
	var readerHead:ReactiveEdge;
	var readerTail:ReactiveEdge;
	var edgeCount:Int = 0;
	var runStamp:Int = 0;
	var captureSources:Array<ReactiveSource>;
	var captureFieldBits:Array<Int>;
	var captureSliceStart:Int = 0;
	var status:Int = Dirty;

	public var dirty(get, never):Bool;
	public function get_dirty():Bool return validateIfNeeded();

	public function new(captureOnly:Bool = false) {
		super();
		this.captureOnly = captureOnly;
		if (captureOnly) status = Clean;
	}

	/** Records a source once in the active run, reusing its edge on the next run. */
	public function track(source:ReactiveSource):Void {
		trackField(source, 0);
	}

	/** Records one field dependency on a shared observable object source. */
	public function trackField(source:ReactiveSource, fieldBit:Int):Void {
		if (source == null) throw "Reactive dependencies require a source";
		source.checkFieldBit(fieldBit);
		if (captureOnly) {
			if (captureSources == null) captureSources = [];
			if (captureFieldBits == null) captureFieldBits = [];
			for (index in captureSliceStart...captureSources.length)
				if (haxeon.Identity.same(captureSources[index], source) && captureFieldBits[index] == fieldBit) return;
			captureSources.push(source);
			captureFieldBits.push(fieldBit);
			return;
		}
		var edge = source.findReader(this, fieldBit);
		if (edge == null) {
			ReactiveRuntime.claimSubscriptionOwner(source, fieldBit);
			edge = new ReactiveEdge(source, this, fieldBit);
			linkReader(edge);
			source.subscribe(edge);
		}
		edge.stamp = runStamp;
	}

	function linkReader(edge:ReactiveEdge):Void {
		edge.readerPrevious = readerTail;
		edge.readerNext = null;
		if (readerTail == null) readerHead = edge else readerTail.readerNext = edge;
		readerTail = edge;
		edgeCount++;
	}

	public function dependencyCount():Int return captureOnly ? pendingCount() : edgeCount;
	public function dependencyMarker():Int {
		if (!captureOnly) return edgeCount;
		var marker = pendingCount();
		// Each retained computation needs its own slice even when a sibling read
		// the same source earlier in this frame. Keep deduplication within a slice.
		captureSliceStart = marker;
		return marker;
	}

	function unlinkReader(edge:ReactiveEdge):Void {
		if (edge.readerPrevious == null) readerHead = edge.readerNext else edge.readerPrevious.readerNext = edge.readerNext;
		if (edge.readerNext == null) readerTail = edge.readerPrevious else edge.readerNext.readerPrevious = edge.readerPrevious;
		edge.readerPrevious = null;
		edge.readerNext = null;
		edgeCount--;
	}

	function beginDependencies():Void {
		if (runStamp == MaxStamp) {
			var edge = readerHead;
			while (edge != null) { edge.stamp = 0; edge = edge.readerNext; }
			runStamp = 1;
		} else
			runStamp++;
	}

	function finishDependencies():Void {
		var edge = readerHead;
		while (edge != null) {
			var next = edge.readerNext;
			if (edge.stamp != runStamp) {
				edge.source.unsubscribe(edge);
				unlinkReader(edge);
			} else {
				edge.source.ensureCurrent();
				edge.seenVersion = edge.source.versionAt(edge.fieldBit);
			}
			edge = next;
		}
		status = Clean;
	}

	/** A failed run retains only the inputs it reached, without pulling them again. */
	function failDependencies():Void {
		var edge = readerHead;
		while (edge != null) {
			var next = edge.readerNext;
			if (edge.stamp != runStamp) {
				edge.source.unsubscribe(edge);
				unlinkReader(edge);
			} else edge.seenVersion = edge.source.versionAt(edge.fieldBit);
			edge = next;
		}
		status = Failed;
	}

	/** Pulls derived inputs and checks whether any source version changed. */
	function sourcesChanged():Bool {
		var edge = readerHead;
		while (edge != null) {
			edge.source.ensureCurrent();
			if (edge.seenVersion != edge.source.versionAt(edge.fieldBit)) return true;
			edge = edge.readerNext;
		}
		return false;
	}

	public function validateIfNeeded():Bool {
		if (status == Clean) return false;
		if (status == Dirty || status == Failed) return true;
		if (sourcesChanged()) {
			markDirty();
			return true;
		}
		status = Clean;
		return false;
	}

	public function hasMaybeStaleInputs():Bool return status == MaybeStale;
	public function isDirtyState():Bool return status == Dirty || status == Failed;
	public function markClean():Void status = Clean;
	public function markFailed():Void status = Failed;

	/** Publishes a changed computed value after its dependencies have been refreshed. */
	public function publishVersionChange():Void {
		bumpVersion();
		invalidateReaders();
	}

	public function markDirty():Void {
		if (status == Dirty) return;
		status = Dirty;
		bumpVersion();
		invalidateReaders();
		onInvalidated();
	}

	/** Called only once an input's version proves that this reader is stale. */
	public function onInvalidated():Void {}

	/** Pushes a candidate invalidation through the graph; values are checked on demand. */
	public function markMaybeStale():Void {
		// A failed computation stays dirty, but a later input change must propagate again.
		if (status == Failed) {
			onMaybeStale();
			invalidateReaders();
			return;
		}
		if (status != Clean) return;
		status = MaybeStale;
		onMaybeStale();
		invalidateReaders();
	}

	public function onMaybeStale():Void {}

	override public function ensureCurrent():Void
		validateIfNeeded();

	/** Replaces dependencies from a reusable slice of source objects. */
	public function setDependencies(sources:Array<ReactiveSource>, start:Int, end:Int):Void {
		if (captureOnly) throw "A capture-only dependency log cannot subscribe";
		beginDependencies();
		var limit = end > sources.length ? sources.length : end;
		var first = start < 0 ? 0 : start > limit ? limit : start;
		for (index in first...limit) track(sources[index]);
		finishDependencies();
	}

	public function pendingCount():Int
		return captureSources == null ? 0 : captureSources.length;

	public function pendingSourceAt(index:Int):ReactiveSource
		return captureSources[index];

	public function pendingFieldBitAt(index:Int):Int
		return captureFieldBits[index];

	public function truncatePending(marker:Int):Void {
		if (captureSources != null) {
			captureSources.resize(marker < 0 ? 0 : marker > captureSources.length ? captureSources.length : marker);
			captureFieldBits.resize(captureSources.length);
			captureSliceStart = captureSources.length;
		} else captureSliceStart = 0;
	}

	public function clearPending():Void {
		if (captureSources != null) captureSources.resize(0);
		if (captureFieldBits != null) captureFieldBits.resize(0);
		captureSliceStart = 0;
	}

	public function appendDependenciesTo(target:ReactiveDependencySet):Void {
		if (captureOnly) {
			if (captureSources != null) for (index in 0...captureSources.length)
				target.trackField(captureSources[index], captureFieldBits[index]);
			return;
		}
		var edge = readerHead;
		while (edge != null) { target.trackField(edge.source, edge.fieldBit); edge = edge.readerNext; }
	}

	/** Unsubscribe retained readers when their owning cache or context is released. */
	public function clearDependencies():Void {
		var edge = readerHead;
		while (edge != null) {
			var next = edge.readerNext;
			edge.source.unsubscribe(edge);
			edge.readerPrevious = null;
			edge.readerNext = null;
			edge.sourcePrevious = null;
			edge.sourceNext = null;
			edge = next;
		}
		readerHead = null;
		readerTail = null;
		edgeCount = 0;
		status = Dirty;
	}
}
