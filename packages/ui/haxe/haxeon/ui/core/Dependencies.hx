package haxeon.ui.core;

import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;

/** Reusable tracked field and signal dependencies owned by a retained computation. */
class Dependencies extends ReactiveDependencySet {
	var invalidationContext:Null<BuildContext>;
	var invalidationBuild:Null<SelfUpdatingBuild>;

	public function new(captureOnly:Bool = false)
		super(captureOnly);

	public function setInvalidationOwner(context:Null<BuildContext>, build:Null<SelfUpdatingBuild>):Void {
		// Retargeting invalidation only changes who is notified; the tracked inputs still decide validity.
		invalidationContext = context;
		invalidationBuild = build;
	}

	/** A reused dependency record belongs to its most recent updater. */
	public function ownedBy(build:SelfUpdatingBuild):Bool
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

	public function addAll(other:Dependencies):Void {
		if (other != this)
			other.appendDependenciesTo(this);
	}

	public function current():Bool
		return !super.get_dirty();

	public function trackedSourcesDirty():Bool
		return super.get_dirty();

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

	public function truncate(marker:Int):Void
		if (captureOnly) truncatePending(marker);

	public function clear():Void
		if (captureOnly) clearPending();

	public function dispose():Void {
		clearDependencies();
		clear();
		invalidationContext = null;
		invalidationBuild = null;
	}
}
