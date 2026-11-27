package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;

/** Reusable tracked field and signal dependencies owned by a retained computation. */
class Dependencies extends ReactiveDependencySet implements Disposable {

	/** An empty record; `captureOnly` makes a frame's scratch capture rather than a retained record. */
	public function new(captureOnly:Bool = false)
		super(captureOnly);

	/** Copies a frame-local slice into this retained record, reusing its subscriptions. */
	public function replaceSlice(source:Dependencies, marker:Int):Void {
		if (captureOnly || source == this)
			throw "A retained dependency record needs a separate frame capture";
		beginDependencies();
		var start = marker < 0 ? 0 : marker > source.pendingCount() ? source.pendingCount() : marker;
		for (index in start...source.pendingCount())
			trackField(source.pendingSourceAt(index), source.pendingFieldBitAt(index));
		finishDependencies();
	}

	internal function addAll(other:Dependencies):Void {
		if (other != this)
			other.appendDependenciesTo(this);
	}

	/** Whether nothing it records has changed since it was taken: what it computed is still valid. */
	public function current():Bool
		return !super.get_dirty();

	override public function onInvalidated():Void ReactiveRuntime.changed();

	internal function truncate(marker:Int):Void
		if (captureOnly) truncatePending(marker);

	/** Forgets what a capture recorded; a retained record keeps its reads. */
	public function clear():Void
		if (captureOnly) clearPending();

	public function dispose():Void {
		clearDependencies();
		clear();
	}
}
