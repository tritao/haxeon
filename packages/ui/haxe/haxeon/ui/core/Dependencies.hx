package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;

/** Reusable tracked field and signal dependencies owned by a retained computation. */
class Dependencies extends ReactiveDependencySet implements Disposable {
	var invalidationContext:Null<BuildContext>;
	var invalidationBuild:Null<SelfUpdatingBuild>;

	/** An empty record; `captureOnly` makes a frame's scratch capture rather than a retained record. */
	public function new(captureOnly:Bool = false)
		super(captureOnly);

	internal function setInvalidationOwner(context:Null<BuildContext>, build:Null<SelfUpdatingBuild>):Void {
		// Retargeting invalidation only changes who is notified; the tracked inputs still decide validity.
		invalidationContext = context;
		invalidationBuild = build;
	}

	/** A reused dependency record belongs to its most recent updater. */
	internal function ownedBy(build:SelfUpdatingBuild):Bool
		return invalidationBuild == build;

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

	internal function trackedSourcesDirty():Bool
		return super.get_dirty();

	/** Asks for the computation that owns it to be patched when something it read may have changed. */
	override public function onMaybeStale():Void {
		var context = invalidationContext;
		var build = invalidationBuild;
		if (context != null && build != null && build.root != null)
			context.requestReactivePatch(build.root.id);
	}

	override public function onInvalidated():Void {
		ReactiveRuntime.changed();
		var context = invalidationContext;
		var build = invalidationBuild;
		if (context != null && build != null && build.root != null)
			context.requestReactivePatch(build.root.id);
	}

	internal function truncate(marker:Int):Void
		if (captureOnly) truncatePending(marker);

	/** Forgets what a capture recorded; a retained record keeps its reads. */
	public function clear():Void
		if (captureOnly) clearPending();

	public function dispose():Void {
		clearDependencies();
		clear();
		invalidationContext = null;
		invalidationBuild = null;
	}
}
