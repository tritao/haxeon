package haxeon.reactive;

/** Tracking is local to the executing thread; reactive graphs remain owned by their application thread. */
class ReactiveRuntime {
  #if wasm
  static final tracking = new sys.thread.Tls<ReactiveCollector>();
  static final ownerThread:Int = sys.thread.ThreadState.current;
  #else
  static final ownerClaimed:Bool = reactiveClaimOwner();
  #end
  static final creationLogs = new sys.thread.Tls<ReactiveCreationLog>();
  static final pendingEffects:Array<Effect> = makePendingEffects();
  static var flushing:Bool = false;
  // The queue has one owner and cannot be flushed recursively. Keeping its cursor with
  // the queue also lets exception recovery see it without allocating a captured cell.
  static var flushIndex:Int = 0;
  static var flushFirstError:Dynamic = null;
  static var flushHasError:Bool = false;
  /** Additional failures from the last non-empty flush, after the first error. */
  public static var lastFlushSuppressedErrors(default, null):Int = 0;
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

  /** Records an Observable allocated by this tracking invocation without retaining it afterwards. */
  public static function recordObservableCreation(object:Dynamic):Void {
    if (!isTracking()) return;
    var log = creationLogs.value;
    if (log == null) {
      log = new ReactiveCreationLog();
      creationLogs.value = log;
    }
    log.append(object);
  }

  static function finishCreationScope(previousStart:Int, previousCount:Int, previous:Null<ReactiveCollector>):Void {
    var log = creationLogs.value;
    if (log != null) {
      log.clearFrom(previousCount);
      log.start = previousStart;
      // A transient stand-in thread must not retain its log after its outermost scope.
      if (previous == null && previousCount == 0 && !isOwnerThread()) creationLogs.value = null;
    }
  }

  /** Reactive subscriptions and observed writes belong to the application thread. */
  @:allow(haxeon.reactive.ReactiveDependencySet) static function claimSubscriptionOwner(
    source:ReactiveSource,
    fieldBit:Int
  ):Void {
    if (!isOwnerThread()) throw 'Cannot subscribe to reactive field $fieldBit from a non-owner thread';
  }

  static function isOwnerThread():Bool {
    #if wasm
    return ownerThread == sys.thread.ThreadState.current;
    #else
    return ownerClaimed && reactiveIsOwner();
    #end
  }


  /** Creates a source once, using the concrete object's Observable layout. */
  public static function createObservableSource(fieldCount:Int):ObservableSource return new ObservableSource(fieldCount);

  /** Shared slow path for a tracked Observable read. */
  public static function recordObservableRead(source:ObservableSource,
    fieldBit:Int):Void source.recordFieldRead(fieldBit);

  /** Shared slow path after a changed Observable field has been assigned. */
  public static function invalidateObservable(source:Null<ObservableSource>, fieldBit:Int):Void {
    if (source != null) source.invalidateField(fieldBit);
  }

  /** Publishes a change from an external retained computation. */
  public static function changed():Void version = version == 0x7fffffff ? 1 : version + 1;

  /** Enter tracking for a direct method call; callers restore the returned value on success and failure. */
  public static function enterTracking(collector:ReactiveCollector):TrackingFrame {
    if (collector == null) throw "Reactive tracking requires a collector";
    var previous = currentCollector();
    var log = creationLogs.value;
    var previousStart = log == null ? 0 : log.start;
    var previousCount = log == null ? 0 : log.count;
    if (log != null) log.start = previousCount;
    setCollector(collector);
    return new TrackingFrame(previous, previousStart, previousCount);
  }

  public static function leaveTracking(frame:TrackingFrame):Void {
    setCollector(frame.previous);
    finishCreationScope(frame.previousStart, frame.previousCount, frame.previous);
  }

  public static function withTracking<T>(collector:ReactiveCollector, run:Void -> T):T {
    if (run == null) throw "Reactive tracking requires a computation";
    var frame = enterTracking(collector);
    try {
      var result = run();
      leaveTracking(frame);
      return result;
    } catch (error:Dynamic) {
      leaveTracking(frame);
      throw error;
    }
  }

  /** Runs a framework callback outside the build/effect scope that scheduled it. */
  public static function withoutTracking<T>(run:Void -> T):T {
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
  public static function withoutTracking1<T>(run:T -> Void, value:T):Void {
    var previous = currentCollector();
    if (previous == null) {
      run(value);
      return;
    }
    setCollector(null);
    try {
      run(value);
      setCollector(previous);
    } catch (error:Dynamic) {
      setCollector(previous);
      throw error;
    }
  }

  @:allow(haxeon.reactive.ReactiveSource) static function track(source:ReactiveSource):Void {
    var current = currentCollector();
    if (current != null) current.track(source);
  }

  @:allow(haxeon.reactive.ObservableSource) static function trackField(source:ReactiveSource, fieldBit:Int):Void {
    var current = currentCollector();
    if (current != null) current.trackField(source, fieldBit);
  }

  /** Signal writes are forbidden in every tracking invocation. */
  public static function assertSignalWritable(source:ReactiveSource, ?operation:String):Void {
    if (isTracking()) throw "Cannot write " + (operation
      == null ? "a signal, State or Observable field" : operation) + " inside a reactive tracking scope";
    if (source.hasFieldReaders(0) && !isOwnerThread()) throw "Cannot write Signal.value from a non-owner thread";
  }

  /** 0 permits a write, 1 rejects a tracked write, and 2 rejects a write by another thread. */
  public static function observableWriteStatus(source:Null<ObservableSource>, fieldBit:Int, owner:Dynamic):Int {
    if (isTracking()) {
      var log = creationLogs.value;
      if (log == null || !log.contains(owner)) return 1;
    }
    if (source != null && source.hasFieldReaders(fieldBit) && !isOwnerThread()) return 2;
    return 0;
  }

  @:allow(haxeon.reactive.Effect) static function enqueue(effect:Effect):Void {
    if (!effect.pending && !effect.disposed) {
      effect.pending = true;
      pendingEffects.push(effect);
    }
  }

  /** Recomputes queued effects once after the frame's writes have settled. */
  public static function flushEffects():Void {
    if (flushing || isTracking() || pendingEffects.length == 0) return;
    flushing = true;
    flushIndex = 0;
    flushHasError = false;
    flushFirstError = null;
    lastFlushSuppressedErrors = 0;
    while (flushIndex < pendingEffects.length) {
      flushIndex++;
      try {
        var effect = pendingEffects[flushIndex - 1];
        effect.pending = false;
        if (!effect.disposed && effect.dirty) effect.run();
      } catch (error:Dynamic) {
        // Validation can throw before runBody marks the effect as failed.
        pendingEffects[flushIndex - 1].markFailed();
        if (!flushHasError) {
          flushFirstError = error;
          flushHasError = true;
        } else lastFlushSuppressedErrors++;
      }
    }
    pendingEffects.resize(0);
    flushIndex = 0;
    flushing = false;
    if (flushHasError) {
      var first = flushFirstError;
      flushFirstError = null;
      flushHasError = false;
      throw first;
    }
  }
}

/** Reused per-thread object identities, with one slice per nested tracking invocation. */
private class ReactiveCreationLog {
  final objects:Array<Dynamic> = [];
  public var start:Int = 0;
  public var count:Int = 0;
  public function new() {
  }
  public function append(object:Dynamic):Void {
    if (count == objects.length) objects.push(object);
    else objects[count] = object;
    count++;
  }
  public function contains(object:Dynamic):Bool {
    var index = count;
    while (index > start) {
      index--;
      if (objects[index] == object) return true;
    }
    return false;
  }
  public function clearFrom(first:Int):Void {
    while (count > first) {
      count--;
      objects[count] = null;
    }
  }
}

#if !wasm
@:hlNative("haxeon_runtime", "__reactive_is_tracking") extern function reactiveIsTracking():Bool;

@:hlNative("haxeon_runtime", "__reactive_claim_owner") extern function reactiveClaimOwner():Bool;

@:hlNative("haxeon_runtime", "__reactive_is_owner") extern function reactiveIsOwner():Bool;

@:hlNative("haxeon_runtime", "__reactive_current_collector") extern function reactiveCurrentCollector():Dynamic;

@:hlNative("haxeon_runtime", "__reactive_set_collector") extern function reactiveSetCollector(value:Dynamic):Void;

#end
