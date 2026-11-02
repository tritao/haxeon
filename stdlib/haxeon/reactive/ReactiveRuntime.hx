package haxeon.reactive;

/** Tracking is local to the executing thread; reactive graphs remain owned by their application thread. */
class ReactiveRuntime {
	#if wasm
	static final tracking = new sys.thread.Tls<ReactiveCollector>();
	#end
	static final pendingEffects:Array<Effect> = [];
	static var flushing:Bool = false;
	public static var version(default, null):Int = 0;

	/** Compiler-generated field reads branch on this once before loading per-object tracking state. */
	public static function isTracking():Bool {
		#if wasm
		return currentCollector() != null;
		#else
		return reactiveIsTracking();
		#end
	}

	static function currentCollector():Null<ReactiveCollector> {
		#if wasm
		return tracking.value;
		#else
		return reactiveCurrentCollector();
		#end
	}

	static function setCollector(value:Null<ReactiveCollector>):Void {
		#if wasm
		tracking.value = value;
		#else
		reactiveSetCollector(value);
		#end
	}


	/** Shared slow path for a tracked Observable read. */
	public static function recordObservableRead(source:Null<ObservableSource>, fieldBit:Int, fieldCount:Int):ObservableSource {
		if (source == null) source = new ObservableSource(fieldCount);
		source.recordFieldRead(fieldBit);
		return source;
	}

	/** Shared slow path after a changed Observable field has been assigned. */
	public static function invalidateObservable(source:Null<ObservableSource>, fieldBit:Int):Void {
		if (source != null) source.invalidateField(fieldBit);
	}

	/** Publishes a change from an external retained computation. */
	public static function changed():Void
		version = version == 0x7fffffff ? 1 : version + 1;

	public static function withTracking<T>(collector:ReactiveCollector, run:Void->T):T {
		if (collector == null || run == null)
			throw "Reactive tracking requires a collector and computation";
		var previous = currentCollector();
		setCollector(collector);
		try {
			var result = run();
			setCollector(previous);
			return result;
		} catch (error:Dynamic) {
			setCollector(previous);
			throw error;
		}
	}

	/** Runs a framework callback outside the build/effect scope that scheduled it. */
	public static function withoutTracking<T>(run:Void->T):T {
		var previous = currentCollector();
		if (previous == null) return run();
		setCollector(null);
		try {
			var result = run();
			setCollector(previous);
			return result;
		} catch (error:Dynamic) {
			setCollector(previous);
			throw error;
		}
	}

	/** Runs a one-argument framework callback without allocating a wrapper closure. */
	public static function withoutTracking1<T>(run:T->Void, value:T):Void {
		var previous = currentCollector();
		if (previous == null) { run(value); return; }
		setCollector(null);
		try {
			run(value);
			setCollector(previous);
		} catch (error:Dynamic) {
			setCollector(previous);
			throw error;
		}
	}

	@:allow(haxeon.reactive.ReactiveSource)
	static function track(source:ReactiveSource):Void {
		var current = currentCollector();
		if (current != null)
			current.track(source);
	}

	@:allow(haxeon.reactive.ObservableSource)
	static function trackField(source:ReactiveSource, fieldBit:Int):Void {
		var current = currentCollector();
		if (current != null)
			current.trackField(source, fieldBit);
	}

	/** A signal write is forbidden while tracking only after a computation has subscribed to its value. */
	public static function assertSignalWritable(source:ReactiveSource, ?operation:String):Void {
		if (isTracking() && source.hasFieldReaders(0))
			throw "Cannot write " + (operation == null ? "a signal, State or Observable field" : operation) +
				" inside a reactive tracking scope";
	}

	/** An Observable field is protected only after another computation has subscribed to that field. */
	public static function observableWriteBlocked(source:Null<ObservableSource>, fieldBit:Int):Bool
		return isTracking() && source != null && source.hasFieldReaders(fieldBit);

	@:allow(haxeon.reactive.Effect)
	static function enqueue(effect:Effect):Void {
		if (!effect.pending && !effect.disposed) {
			effect.pending = true;
			pendingEffects.push(effect);
		}
	}

	/** Recomputes queued effects once after the frame's writes have settled. */
	public static function flushEffects():Void {
		if (flushing || isTracking() || pendingEffects.length == 0)
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

#if !wasm
@:hlNative("haxeon_runtime", "__reactive_is_tracking")
extern function reactiveIsTracking():Bool;

@:hlNative("haxeon_runtime", "__reactive_current_collector")
extern function reactiveCurrentCollector():Dynamic;

@:hlNative("haxeon_runtime", "__reactive_set_collector")
extern function reactiveSetCollector(value:Dynamic):Void;
#end
