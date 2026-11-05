import haxeon.reactive.Signal;
import haxeon.reactive.Effect;
import haxeon.reactive.ReactiveRuntime;

struct EqualWritePart implements Equatable {
	public final value:Int;
	public function new(value:Int) this.value = value;
	public function equals(other:EqualWritePart):Bool return value % 10 == other.value % 10;
}
class EqualWriteModel implements Observable {
	public var ratio:Float = 0.0;
	public var item:EqualWritePart;
	public function new(item:EqualWritePart) this.item = item;
}
function negativeZero():Float {
	var zero = 0.0;
	return zero * -1.0;
}
function main():Int {
	var model = new EqualWriteModel(new EqualWritePart(2));
	var runs = 0;
	var effect = new Effect(function() { var a = model.item; var b = model.ratio; runs++; });
	model.item = new EqualWritePart(12);
	if (model.item.value != 12 || effect.dirty) return 1;
	model.ratio = negativeZero();
	if (1.0 / model.ratio >= 0.0 || effect.dirty) return 2;
	var signal = new Signal<Float>(0.0);
	var signalRuns = 0;
	var signalEffect = new Effect(function() { var value = signal.value; signalRuns++; });
	signal.value = negativeZero();
	if (1.0 / signal.value >= 0.0 || signalEffect.dirty) return 3;
	var zero = 0.0, nan = zero / zero;
	model.ratio = nan;
	signal.value = nan;
	ReactiveRuntime.flushEffects();
	model.ratio = nan;
	signal.value = nan;
	if (effect.dirty || signalEffect.dirty || runs != 2 || signalRuns != 2) return 4;
	effect.dispose(); signalEffect.dispose();
	return 42;
}
