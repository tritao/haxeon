package haxeon.audio;

import sys.thread.Condition;
import sys.thread.Lock;
import sys.thread.Thread;

private typedef PreparationJob<T> = {
    var prepare:Void -> T;
    var ready:T -> Void;
    var failed:Dynamic -> Void;
    var discard:T -> Void;
}
private typedef PreparationResult<T> = {
    var job:PreparationJob<T>;
    var value:Null<T>;
    var error:Dynamic;
    var success:Bool;
}

/** Bounded worker for score compilation, patch/sample preparation and SF2 loading.
 * Publish results with update() on the owning control thread. Audio timing stays native.
 * ready() takes ownership when it returns successfully; discard() handles cancellation
 * and failed publication. Dispose joins the worker and discards unpublished values.
 */
class AudioPreparation<T> {
    final condition = new Condition();
    final finished = new Lock();
    final jobs:Array<PreparationJob<T>> = [];
    final results:Array<PreparationResult<T>> = [];
    final capacity:Int;
    var outstanding:Int = 0;
    var closed:Bool = false;
    var disposed:Bool = false;

    public function new(capacity:Int = 8) {
        if (capacity < 1 || capacity > 64) throw "Audio preparation capacity must be 1..64";
        this.capacity = capacity;
        #if !wasm
        Thread.create(run);
        #end
    }
    /** Returns false without taking ownership when the bounded queue is full. */
    public function submit(prepare:Void -> T, ready:T -> Void, failed:Dynamic -> Void,
        discard:T -> Void):Bool {
        condition.acquire();
        if (closed || outstanding == capacity) { condition.release(); return false; }
        var job:PreparationJob<T> = {prepare:prepare, ready:ready, failed:failed, discard:discard};
        outstanding++;
        #if wasm
        condition.release();
        var result = execute(job);
        condition.acquire(); results.push(result); condition.release();
        #else
        jobs.push(job); condition.signal(); condition.release();
        #end
        return true;
    }
    function execute(job:PreparationJob<T>):PreparationResult<T> {
        try return {job:job, value:job.prepare(), error:null, success:true}
        catch (error:Dynamic) return {job:job, value:null, error:error, success:false};
    }
    #if !wasm
    function run():Void {
        while (true) {
            condition.acquire();
            while (jobs.length == 0 && !closed) condition.wait();
            if (closed) { condition.release(); break; }
            var job:PreparationJob<T> = cast jobs.shift();
            condition.release();
            var result = execute(job);
            condition.acquire(); results.push(result); condition.release();
        }
        finished.release();
    }
    #end
    /** Deliver completed work outside the worker mutex. */
    public function update():Void {
        if (disposed) throw "Audio preparation worker disposed";
        condition.acquire();
        var ready = results.copy(); results.resize(0); outstanding -= ready.length;
        condition.release();
        var failure:Dynamic = null;
        for (result in ready) {
          try {
            if (disposed) {
                if (result.success) result.job.discard(cast result.value);
            } else if (!result.success) result.job.failed(result.error);
            else {
                var value:T = cast result.value;
                try result.job.ready(value) catch (error:Dynamic) {
                    var cleanup:Dynamic = null;
                    try result.job.discard(value) catch (discardError:Dynamic) cleanup = discardError;
                    result.job.failed(error);
                    if (cleanup != null) throw cleanup;
                }
            }
          } catch (error:Dynamic) { if (failure == null) failure = error; }
        }
        if (failure != null) throw failure;
    }
    public function dispose():Void {
        if (disposed) return;
        condition.acquire(); closed = true; jobs.resize(0); condition.broadcast(); condition.release();
        #if !wasm
        finished.wait();
        #end
        condition.acquire();
        var abandoned = results.copy(); results.resize(0); outstanding = 0;
        condition.release(); disposed = true;
        var failure:Dynamic = null;
        for (result in abandoned) if (result.success) {
            try result.job.discard(cast result.value) catch (error:Dynamic) {
                if (failure == null) failure = error;
            }
        }
        if (failure != null) throw failure;
    }
}
