package haxeon.reactive;

/** Reusable dependency edges for a derived value, effect or retained computation. */
class ReactiveDependencySet extends ReactiveSource implements ReactiveCollector {
	static inline var Clean:Int = 0;
	static inline var MaybeStale:Int = 1;
	static inline var Dirty:Int = 2;
	static inline var MaxStamp:Int = 0x7fffffff;

	public final captureOnly:Bool;
	var edgesBySource:Map<Int, ReactiveEdge>;
	var readerHead:ReactiveEdge;
	var readerTail:ReactiveEdge;
	var edgeCount:Int = 0;
	var runStamp:Int = 0;
	var captureStampKeys:Array<Int>;
	var captureStampValues:Array<Int>;
	var captureStampCount:Int = 0;
	var captureStampUsed:Int = 0;
	var captureStampIds:Array<Int>;
	var captureSources:Array<ReactiveSource>;
	var captureFieldBits:Array<Int>;
	var captureStamp:Int = 1;
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
		var dependencyId = source.dependencyId(fieldBit);
		if (captureOnly) {
			if (captureSources == null) captureSources = [];
			if (captureFieldBits == null) captureFieldBits = [];
			var priorStamp = getCaptureStamp(dependencyId);
			if (priorStamp < 0) {
				if (captureStampIds == null) captureStampIds = [];
				captureStampIds.push(dependencyId);
			}
			if (priorStamp != captureStamp) {
				setCaptureStamp(dependencyId, captureStamp);
				captureSources.push(source);
				captureFieldBits.push(fieldBit);
			}
			return;
		}
		var edge = findEdge(source, fieldBit);
		if (edge == null) {
			ReactiveRuntime.claimSubscriptionOwner(source, fieldBit);
			edge = new ReactiveEdge(source, this, fieldBit);
			if (edgesBySource == null) edgesBySource = new Map();
			edgesBySource.set(dependencyId, edge);
			linkReader(edge);
			source.subscribe(edge);
		}
		edge.stamp = runStamp;
	}

	function findEdge(source:ReactiveSource, fieldBit:Int):Null<ReactiveEdge>
		return edgesBySource == null ? null : edgesBySource.get(source.dependencyId(fieldBit));

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
		advanceCaptureStamp();
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
				edgesBySource.remove(edge.source.dependencyId(edge.fieldBit));
			} else {
				edge.source.ensureCurrent();
				edge.seenVersion = edge.source.versionAt(edge.fieldBit);
			}
			edge = next;
		}
		status = Clean;
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
		if (status == Dirty) return true;
		if (sourcesChanged()) {
			markDirty();
			return true;
		}
		status = Clean;
		return false;
	}

	public function hasMaybeStaleInputs():Bool return status == MaybeStale;
	public function isDirtyState():Bool return status == Dirty;
	public function markClean():Void status = Clean;
	public function markFailed():Void status = Dirty;

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
		}
		advanceCaptureStamp();
	}

	public function clearPending():Void {
		sweepCaptureStamps();
		if (captureSources != null) captureSources.resize(0);
		if (captureFieldBits != null) captureFieldBits.resize(0);
		advanceCaptureStamp();
	}

	function advanceCaptureStamp():Void {
		if (captureStamp == MaxStamp) {
			clearCaptureStamps();
			captureStamp = 1;
			if (captureSources != null) for (index in 0...captureSources.length) {
				var source = captureSources[index], dependencyId = source.dependencyId(captureFieldBits[index]);
				if (getCaptureStamp(dependencyId) < 0)
					captureStampIds.push(dependencyId);
				setCaptureStamp(dependencyId, captureStamp);
			}
		} else
			captureStamp++;
	}

	function clearCaptureStamps():Void {
		if (captureStampIds != null) {
			for (id in captureStampIds) removeCaptureStamp(id);
			captureStampIds.resize(0);
		}
	}

	/** Retain entries for sources still in this capture so the next frame reuses their table slots. */
	function sweepCaptureStamps():Void {
		if (captureStampIds == null) return;
		if (captureSources != null) for (index in 0...captureSources.length)
			setCaptureStamp(captureSources[index].dependencyId(captureFieldBits[index]), 0);
		var write = 0;
		for (id in captureStampIds) {
			if (getCaptureStamp(id) == 0)
				captureStampIds[write++] = id;
			else
				removeCaptureStamp(id);
		}
		captureStampIds.resize(write);
	}

	/** Open-addressed integer stamps avoid one HashLink map node per source on every frame. */
	function getCaptureStamp(id:Int):Int {
		if (captureStampKeys == null) return -1;
		var mask = captureStampKeys.length - 1;
		var index = captureStampHash(id) & mask;
		for (_ in 0...captureStampKeys.length) {
			var key = captureStampKeys[index];
			if (key == 0) return -1;
			if (key == id) return captureStampValues[index];
			index = (index + 1) & mask;
		}
		return -1;
	}

	function setCaptureStamp(id:Int, stamp:Int):Void {
		if (captureStampKeys == null) resizeCaptureStamps(16);
		var existing = captureStampIndex(id);
		if (existing >= 0) {
			captureStampValues[existing] = stamp;
			return;
		}
		if ((captureStampCount + 1) * 3 > captureStampKeys.length * 2)
			resizeCaptureStamps(captureStampKeys.length * 2);
		else if ((captureStampUsed + 1) * 3 > captureStampKeys.length * 2)
			resizeCaptureStamps(captureStampKeys.length);
		var mask = captureStampKeys.length - 1;
		var index = captureStampHash(id) & mask;
		var deleted = -1;
		for (_ in 0...captureStampKeys.length) {
			var key = captureStampKeys[index];
			if (key == -1 && deleted < 0)
				deleted = index;
			if (key == 0) {
				var target = deleted < 0 ? index : deleted;
				captureStampKeys[target] = id;
				captureStampValues[target] = stamp;
				captureStampCount++;
				if (deleted < 0) captureStampUsed++;
				return;
			}
			index = (index + 1) & mask;
		}
		if (deleted >= 0) {
			captureStampKeys[deleted] = id;
			captureStampValues[deleted] = stamp;
			captureStampCount++;
			return;
		}
		resizeCaptureStamps(captureStampKeys.length * 2);
		setCaptureStamp(id, stamp);
	}

	function removeCaptureStamp(id:Int):Void {
		if (captureStampKeys == null) return;
		var mask = captureStampKeys.length - 1;
		var index = captureStampHash(id) & mask;
		for (_ in 0...captureStampKeys.length) {
			var key = captureStampKeys[index];
			if (key == 0) return;
			if (key == id) {
				captureStampKeys[index] = -1;
				captureStampValues[index] = 0;
				captureStampCount--;
				return;
			}
			index = (index + 1) & mask;
		}
	}

	function captureStampIndex(id:Int):Int {
		var mask = captureStampKeys.length - 1;
		var index = captureStampHash(id) & mask;
		for (_ in 0...captureStampKeys.length) {
			var key = captureStampKeys[index];
			if (key == 0) return -1;
			if (key == id) return index;
			index = (index + 1) & mask;
		}
		return -1;
	}

	function resizeCaptureStamps(capacity:Int):Void {
		var oldKeys = captureStampKeys;
		var oldValues = captureStampValues;
		captureStampKeys = [];
		captureStampValues = [];
		captureStampKeys.resize(capacity);
		captureStampValues.resize(capacity);
		for (index in 0...capacity) {
			captureStampKeys[index] = 0;
			captureStampValues[index] = 0;
		}
		captureStampCount = 0;
		captureStampUsed = 0;
		if (oldKeys != null) for (index in 0...oldKeys.length) {
			var id = oldKeys[index];
			if (id > 0) setCaptureStamp(id, oldValues[index]);
		}
	}

	static inline function captureStampHash(id:Int):Int {
		var hash = id;
		hash ^= hash >>> 16;
		hash *= 0x7feb352d;
		hash ^= hash >>> 15;
		hash *= 0x846ca68b;
		hash ^= hash >>> 16;
		return hash;
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
		edgesBySource = null;
		status = Dirty;
	}
}
