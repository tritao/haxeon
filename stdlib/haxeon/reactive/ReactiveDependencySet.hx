package haxeon.reactive;

/** Reusable dependency edges for a derived value, effect or retained computation. */
class ReactiveDependencySet extends ReactiveSource implements ReactiveCollector {
	static inline var Clean:Int = 0;
	static inline var MaybeStale:Int = 1;
	static inline var Dirty:Int = 2;
	static inline var Failed:Int = 3;
	static inline var MaxStamp:Int = 0x7fffffff;
	static inline var IndexThreshold:Int = 1024;

	public final captureOnly:Bool;
	var readerHead:ReactiveEdge;
	// The capture-only form has no edge tail and uses this slot for its index.
	var readerTail:Dynamic;
	var edgeCount:Int = 0;
	var runStamp:Int = 0;
	// Capture-only readers use this for their source array. Subscribing readers
	// use the otherwise unused slot for their optional large-reader index.
	var captureSources:Dynamic;
	var captureFieldBits:Array<Int>;
	// Capture readers store the slice start; subscribing readers count fallback
	// scan work until an index is warranted.
	var captureSliceStart:Int = 0;
	var status:Int = Dirty;

	inline function captureArray():Array<ReactiveSource> return cast captureSources;
	inline function getIdentityIndex():ReactiveIdentityIndex return captureOnly ? cast readerTail : cast captureSources;
	inline function setIdentityIndex(index:ReactiveIdentityIndex):Void {
		if (captureOnly) readerTail = index else captureSources = index;
	}

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
			if (captureSources == null) { var initial:Array<ReactiveSource> = []; captureSources = initial; }
			if (captureFieldBits == null) captureFieldBits = [];
			var sources = captureArray(), identityIndex = getIdentityIndex();
			if (identityIndex != null) {
				if (identityIndex.contains(source, fieldBit)) return;
				identityIndex.put(source, fieldBit, null);
			} else {
				for (index in captureSliceStart...sources.length)
					if (haxeon.Identity.same(sources[index], source) && captureFieldBits[index] == fieldBit) return;
				if (sources.length - captureSliceStart >= IndexThreshold) {
					identityIndex = new ReactiveIdentityIndex(true);
					setIdentityIndex(identityIndex);
					for (index in captureSliceStart...sources.length)
						identityIndex.put(sources[index], captureFieldBits[index], null);
					identityIndex.put(source, fieldBit, null);
				}
			}
			sources.push(source);
			captureFieldBits.push(fieldBit);
			return;
		}
		var edge:ReactiveEdge = null, identityIndex = getIdentityIndex(), tail:ReactiveEdge = cast readerTail;
		if (identityIndex != null) edge = identityIndex.get(source, fieldBit);
		else if (tail != null && haxeon.Identity.same(tail.source, source) && tail.fieldBit == fieldBit)
			edge = tail;
		else {
			var first = source.firstReader();
			if (first != null && haxeon.Identity.same(first.reader, this) && first.fieldBit == fieldBit)
				edge = first;
			else if (first != null && first.sourceNext != null) {
				var candidate = readerHead;
				while (candidate != null) {
					if (captureSliceStart < IndexThreshold) captureSliceStart++;
					if (haxeon.Identity.same(candidate.source, source) && candidate.fieldBit == fieldBit) { edge = candidate; break; }
					candidate = candidate.readerNext;
				}
				if (edgeCount > IndexThreshold && captureSliceStart >= IndexThreshold) {
					identityIndex = new ReactiveIdentityIndex(false);
					setIdentityIndex(identityIndex);
					candidate = readerHead;
					while (candidate != null) { identityIndex.put(candidate.source, candidate.fieldBit, candidate); candidate = candidate.readerNext; }
				}
			}
		}
		if (edge == null) {
			ReactiveRuntime.claimSubscriptionOwner(source, fieldBit);
			edge = new ReactiveEdge(source, this, fieldBit);
			linkReader(edge);
			source.subscribe(edge);
			if (identityIndex != null) identityIndex.put(source, fieldBit, edge);
		}
		edge.stamp = runStamp;
	}

	function linkReader(edge:ReactiveEdge):Void {
		var tail:ReactiveEdge = cast readerTail;
		edge.readerPrevious = tail;
		edge.readerNext = null;
		if (tail == null) readerHead = edge else tail.readerNext = edge;
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
		var identityIndex = getIdentityIndex();
		if (identityIndex != null) identityIndex.clear();
		return marker;
	}

	function unlinkReader(edge:ReactiveEdge):Void {
		var identityIndex = getIdentityIndex();
		if (identityIndex != null) identityIndex.remove(edge.source, edge.fieldBit);
		if (edge.readerPrevious == null) readerHead = edge.readerNext else edge.readerPrevious.readerNext = edge.readerNext;
		if (edge.readerNext == null) readerTail = edge.readerPrevious else edge.readerNext.readerPrevious = edge.readerPrevious;
		edge.readerPrevious = null;
		edge.readerNext = null;
		edgeCount--;
	}

	function beginDependencies():Void {
		captureSliceStart = 0;
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
		return !captureOnly || captureSources == null ? 0 : captureArray().length;

	public function pendingSourceAt(index:Int):ReactiveSource
		return captureArray()[index];

	public function pendingFieldBitAt(index:Int):Int
		return captureFieldBits[index];

	public function truncatePending(marker:Int):Void {
		if (!captureOnly) return;
		var identityIndex = getIdentityIndex();
		if (identityIndex != null) identityIndex.clear();
		if (captureSources != null) {
			var sources = captureArray();
			sources.resize(marker < 0 ? 0 : marker > sources.length ? sources.length : marker);
			captureFieldBits.resize(sources.length);
			captureSliceStart = sources.length;
		} else captureSliceStart = 0;
	}

	public function clearPending():Void {
		if (!captureOnly) return;
		var identityIndex = getIdentityIndex();
		if (identityIndex != null) identityIndex.clear();
		if (captureSources != null) captureArray().resize(0);
		if (captureFieldBits != null) captureFieldBits.resize(0);
		captureSliceStart = 0;
	}

	public function appendDependenciesTo(target:ReactiveDependencySet):Void {
		if (captureOnly) {
			if (captureSources != null) {
				var sources = captureArray();
				for (index in 0...sources.length) target.trackField(sources[index], captureFieldBits[index]);
			}
			return;
		}
		var edge = readerHead;
		while (edge != null) { target.trackField(edge.source, edge.fieldBit); edge = edge.readerNext; }
	}

	/** Unsubscribe retained readers when their owning cache or context is released. */
	public function clearDependencies():Void {
		// A capture log has no subscriptions; its pending slice remains intact.
		if (captureOnly) { status = Dirty; return; }
		var identityIndex = getIdentityIndex();
		if (identityIndex != null) identityIndex.clear();
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
