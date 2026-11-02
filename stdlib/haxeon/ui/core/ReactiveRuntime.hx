package haxeon.ui.core;

/** Single-threaded tracking state shared by signals, derived values, effects and UI builds. */
class ReactiveRuntime {
	static var current:Null<ReactiveCollector>;
	static var trackingDepth:Int = 0;
	static final pendingEffects:Array<Effect> = [];
	static var flushing:Bool = false;
	public static var version(default, null):Int = 0;

	/** Compiler-generated field reads branch on this once before loading per-object tracking state. */
	public static function isTracking():Bool
		return trackingDepth > 0;


	/** Compiler-generated Observable reads allocate this only when an object is first read while tracking. */
	public static function createObservableSource(fieldCount:Int):ObservableSource
		return new ObservableSource(fieldCount);

	@:allow(haxeon.ui.core.Dependencies)
	static function changed():Void
		version = version == 0x7fffffff ? 1 : version + 1;

	public static function withTracking<T>(collector:ReactiveCollector, run:Void->T):T {
		if (collector == null || run == null)
			throw "Reactive tracking requires a collector and computation";
		var previous = current;
		current = collector;
		trackingDepth++;
		try {
			var result = run();
			trackingDepth--;
			current = previous;
			return result;
		} catch (error:Dynamic) {
			trackingDepth--;
			current = previous;
			throw error;
		}
	}

	/** Runs a framework callback outside the build/effect scope that scheduled it. */
	public static function withoutTracking<T>(run:Void->T):T {
		var previous = current, previousDepth = trackingDepth;
		current = null;
		trackingDepth = 0;
		try {
			var result = run();
			current = previous;
			trackingDepth = previousDepth;
			return result;
		} catch (error:Dynamic) {
			current = previous;
			trackingDepth = previousDepth;
			throw error;
		}
	}

	/** Runs a one-argument framework callback without allocating a wrapper closure. */
	public static function withoutTracking1<T>(run:T->Void, value:T):Void {
		var previous = current, previousDepth = trackingDepth;
		current = null;
		trackingDepth = 0;
		try {
			run(value);
			current = previous;
			trackingDepth = previousDepth;
		} catch (error:Dynamic) {
			current = previous;
			trackingDepth = previousDepth;
			throw error;
		}
	}

	@:allow(haxeon.ui.core.ReactiveSource)
	static function track(source:ReactiveSource):Void {
		if (current != null)
			current.track(source);
	}

	@:allow(haxeon.ui.core.ObservableSource)
	static function trackField(source:ReactiveSource, fieldBit:Int):Void {
		if (current != null)
			current.trackField(source, fieldBit);
	}

	/** A signal write is forbidden while tracking only after a computation has subscribed to its value. */
	public static function assertSignalWritable(source:ReactiveSource, ?operation:String):Void {
		if (trackingDepth > 0 && source.hasFieldReaders(0))
			throw "Cannot write " + (operation == null ? "a signal, State or Observable field" : operation) +
				" inside a reactive tracking scope";
	}

	/** An Observable field is protected only after another computation has subscribed to that field. */
	public static function observableWriteBlocked(source:Null<ObservableSource>, fieldBit:Int):Bool
		return trackingDepth > 0 && source != null && source.hasFieldReaders(fieldBit);

	@:allow(haxeon.ui.core.Effect)
	static function enqueue(effect:Effect):Void {
		if (!effect.pending && !effect.disposed) {
			effect.pending = true;
			pendingEffects.push(effect);
		}
	}

	/** Recomputes queued effects once after the frame's writes have settled. */
	public static function flushEffects():Void {
		if (flushing || trackingDepth > 0 || pendingEffects.length == 0)
			return;
		flushing = true;
		var index = 0;
		try {
			while (index < pendingEffects.length) {
				var effect = pendingEffects[index++];
				effect.pending = false;
				if (!effect.disposed && effect.dirty)
					effect.run();
			}
			pendingEffects.resize(0);
			flushing = false;
		} catch (error:Dynamic) {
			// Keep effects not yet visited queued for the next flush.
			if (index > 0) pendingEffects.splice(0, index);
			flushing = false;
			throw error;
		}
	}
}
