import haxeon.reactive.Effect;
import haxeon.reactive.ObservableSource;
import haxeon.reactive.ReactiveDependencySet;
import haxeon.reactive.ReactiveRuntime;
import haxeon.reactive.Signal;

class ReactiveScaleCensus {
	static var sources:Array<Signal<Int>>;
	static var capture:ReactiveDependencySet;
	static var effect:Effect;
	static var runs:Int;
	public static function prepare():Void {
		sources = [];
		for (i in 0...2048) sources.push(new Signal(i));
		capture = new ReactiveDependencySet(true);
		perform(1);
		runs = 0;
		effect = new Effect(() -> { for (source in sources) { var value = source.value; } runs++; });
	}
	public static function perform(iterations:Int):Int {
		var total = 0;
		for (iteration in 0...iterations) {
			for (source in sources) { capture.track(source); capture.track(source); }
			total += capture.pendingCount();
			capture.clearPending();
		}
		return total;
	}
	public static function performEffect(iterations:Int):Int {
		var before = runs;
		for (iteration in 0...iterations) effect.retrack();
		return runs - before;
	}
}

function main():Int {
	var shared = new Signal(1), readers:Array<Effect> = [], runs = 0;
	for (i in 0...10000) readers.push(new Effect(() -> { var value = shared.value; runs += value; }));
	if (runs != 10000) return 1;
	for (reader in readers) reader.retrack();
	if (runs != 20000) return 2;
	shared.value = 2;
	ReactiveRuntime.flushEffects();
	if (runs != 40000) return 3;
	for (reader in readers) reader.dispose();

	var sources:Array<Signal<Int>> = [];
	for (i in 0...10000) sources.push(new Signal(i));
	var rowRuns = 0, rowSum = 0;
	var rows = new Effect(() -> {
		var sum = 0;
		for (i in 0...2000) sum += sources[i].value;
		rowSum = sum; rowRuns++;
	});
	if (rows.dependencyCount() != 2000 || rowRuns != 1) return 16;
	sources[0].value = 42; ReactiveRuntime.flushEffects();
	if (rowRuns != 2 || rowSum != 1999042) return 17;
	rows.dispose();
	var wideRuns = 0;
	var wide = new Effect(() -> { for (source in sources) { var value = source.value; } wideRuns++; });
	if (wide.dependencyCount() != 10000) return 18;
	wide.retrack();
	if (wideRuns != 2 || wide.dependencyCount() != 10000) return 19;
	wide.dispose();
	var capture = new ReactiveDependencySet(true);
	for (source in sources) { capture.track(source); capture.track(source); }
	if (capture.pendingCount() != 10000) return 4;
	capture.clearDependencies();
	for (source in sources) capture.track(source);
	if (capture.pendingCount() != 10000) return 21;
	var marker = capture.dependencyMarker();
	for (source in sources) capture.track(source);
	if (capture.pendingCount() != 20000) return 5;
	capture.truncatePending(marker);
	for (source in sources) capture.track(source);
	if (capture.pendingCount() != 20000) return 6;
	capture.clearPending();
	if (capture.pendingCount() != 0) return 7;

	var fields = new ObservableSource(4000), total = 0;
	var effect = new Effect(() -> { for (i in 0...2000) fields.recordFieldRead(i); total++; });
	if (effect.dependencyCount() != 2000) return 8;
	fields.invalidateField(1999); ReactiveRuntime.flushEffects();
	if (total != 2) return 9;
	effect.dispose();
	var even = true;
	var changing = new Effect(() -> { for (i in 0...4000) if ((i % 2 == 0) == even) fields.recordFieldRead(i); });
	if (changing.dependencyCount() != 2000) return 10;
	even = false; changing.retrack();
	if (changing.dependencyCount() != 2000) return 11;
	fields.invalidateField(0);
	if (changing.dirty) return 12;
	fields.invalidateField(1);
	if (!changing.dirty) return 13;
	changing.dispose();
	ReactiveScaleCensus.prepare();
	#if !wasm
	var before = hl.Gc.totalAllocated();
	#end
	if (ReactiveScaleCensus.perform(4) != 8192) return 14;
	if (ReactiveScaleCensus.performEffect(4) != 4) return 20;
	#if !wasm
	if (hl.Gc.totalAllocated() != before) return 15;
	#end
	return 42;
}
