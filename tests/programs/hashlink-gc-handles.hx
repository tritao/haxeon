import runtime.memory.Gc;
import runtime.memory.GcHandle;

class GcHandleValue {
	public final value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var original:Dynamic = new GcHandleValue(17),
		handle = GcHandle.create(original),
		raw = handle.raw();
	if (raw.isNull() || handle.isClosed() || cast(handle.get(), GcHandleValue).value != 17)
		return 1;
	original = null;
	Gc.collect();
	var recovered:GcHandleValue = cast handle.get();
	if (recovered == null || recovered.value != 17)
		return 2;
	handle.set(new GcHandleValue(29));
	if (cast(handle.get(), GcHandleValue).value != 29 || handle.close() == false || !handle.isClosed() || !handle.raw().isNull() || handle.close())
		return 3;
	return 42;
}
