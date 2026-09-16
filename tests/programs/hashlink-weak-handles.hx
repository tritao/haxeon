import runtime.memory.Gc;
import runtime.memory.WeakRoot;

class WeakRootValue {
	public final value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function makeWeak():WeakRoot<WeakRootValue> {
	var value = new WeakRootValue(17);
	return WeakRoot.create(value);
}

function main():Int {
	var weak = makeWeak();
	if (weak.get() == null || weak.raw().isNull())
		return 1;
	Gc.collect();
	if (weak.get() != null || !weak.raw().isNull())
		return 2;

	var retained = new WeakRootValue(29);
	weak.set(retained);
	Gc.collect();
	var observed = weak.get();
	if (observed == null || observed.value != 29)
		return 3;
	retained = null;
	weak.close();
	if (!weak.isClosed() || weak.get() != null || !weak.raw().isNull() || weak.close())
		return 4;
	return 42;
}
