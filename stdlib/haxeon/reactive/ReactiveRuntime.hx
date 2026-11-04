package haxeon.reactive;

/** Tracking is local to the executing thread; reactive graphs remain owned by their application thread. */
class ReactiveRuntime {
	#if wasm
	static final tracking = new sys.thread.Tls<ReactiveCollector>();
	static final ownerThread:Int = sys.thread.ThreadState.current;
	#else
	static final ownerClaimed:Bool = reactiveClaimOwner();
	#end
	static final pendingEffects:Array<Effect> = makePendingEffects();
	static var flushing:Bool = false;
	// The queue has one owner and cannot be flushed recursively. Keeping its cursor with
	// the queue also lets exception recovery see it without allocating a captured cell.
	static var flushIndex:Int = 0;
	public static var version(default, null):Int = 0;

	/** A single pending effect needs no first-use backing-store allocation. */
	static function makePendingEffects():Array<Effect> {
		var effects:Array<Effect> = [null];
		effects.resize(0);
		return effects;
	}

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

	/** Reactive subscriptions and observed writes belong to the application thread. */
	@:allow(haxeon.reactive.ReactiveDependencySet)
	static function claimSubscriptionOwner(source:ReactiveSource, fieldBit:Int):Void {
		if (!isOwnerThread())
			throw 'Cannot subscribe to reactive source ${source.reactiveId} field $fieldBit from a non-owner thread';
	}

	static function isOwnerThread():Bool {
		#if wasm
		return ownerThread == sys.thread.ThreadState.current;
		#else
		return ownerClaimed && reactiveIsOwner();
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
		if (!source.hasFieldReaders(0)) return;
		if (!isOwnerThread())
			throw 'Cannot write Signal.value of reactive source ${source.reactiveId} from a non-owner thread';
		if (isTracking())
			throw "Cannot write " + (operation == null ? "a signal, State or Observable field" : operation) +
				" inside a reactive tracking scope";
	}

	/** 0 permits a write, 1 rejects a tracked write, and 2 rejects a write by another thread. */
	public static function observableWriteStatus(source:Null<ObservableSource>, fieldBit:Int):Int {
		if (source == null || !source.hasFieldReaders(fieldBit)) return 0;
		if (!isOwnerThread()) return 2;
		return isTracking() ? 1 : 0;
	}

	@:allow(haxeon.reactive.Effect)
	static function enqueue(effect:Effect):Void {
		if (!effect.pending && !effect.disposed) {
			effect.pending = true;
			pendingEffects.push(effect);
		}
	}

	/** A failed off-thread subscription must not mutate the owner's pending queue. */
	@:allow(haxeon.reactive.Effect)
	static function retryFailedEffect(effect:Effect):Void {
		if (isOwnerThread()) enqueue(effect);
	}

	/** Recomputes queued effects once after the frame's writes have settled. */
	public static function flushEffects():Void {
		if (flushing || isTracking() || pendingEffects.length == 0)
			return;
		flushing = true;
		flushIndex = 0;
		try {
			while (flushIndex < pendingEffects.length) {
				var effect = pendingEffects[flushIndex++];
				effect.pending = false;
				if (!effect.disposed && effect.dirty)
					effect.run();
			}
			pendingEffects.resize(0);
			flushIndex = 0;
			flushing = false;
		} catch (error:Dynamic) {
			// Retry a failed validation or run after effects not yet visited.
			if (flushIndex > 0) {
				enqueue(pendingEffects[flushIndex - 1]);
				pendingEffects.splice(0, flushIndex);
			}
			flushIndex = 0;
			flushing = false;
			throw error;
		}
	}
}

#if !wasm
@:hlNative("haxeon_runtime", "__reactive_is_tracking")
extern function reactiveIsTracking():Bool;

@:hlNative("haxeon_runtime", "__reactive_claim_owner")
extern function reactiveClaimOwner():Bool;

@:hlNative("haxeon_runtime", "__reactive_is_owner")
extern function reactiveIsOwner():Bool;

@:hlNative("haxeon_runtime", "__reactive_current_collector")
extern function reactiveCurrentCollector():Dynamic;

@:hlNative("haxeon_runtime", "__reactive_set_collector")
extern function reactiveSetCollector(value:Dynamic):Void;
#end
