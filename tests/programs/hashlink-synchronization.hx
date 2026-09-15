import runtime.memory.ConditionVariable;
import runtime.memory.Gc;
import runtime.memory.Mutex;
import runtime.memory.Tls;
import runtime.memory.TlsRuntime;

class TlsValue {
	public final value:Int;

	public function new(value:Int) {
		this.value = value;
	}
}

function main():Int {
	var mutex = Mutex.create(),
		condition = ConditionVariable.create(),
		tls = TlsRuntime.create();
	if (!mutex.tryAcquire())
		return 1;
	mutex.acquire();
	mutex.release();
	mutex.release();
	condition.acquire();
	var timedOut = !condition.timedWait(0.0);
	condition.signal();
	condition.broadcast();
	condition.release();
	if (!timedOut || !condition.tryAcquire())
		return 2;
	condition.release();
	var value:Dynamic = new TlsValue(31);
	tls.set(value);
	value = null;
	Gc.collect();
	var recovered:TlsValue = cast tls.get();
	if (recovered == null || recovered.value != 31)
		return 3;
	tls.clear();
	if (tls.get() != null)
		return 4;
	tls.close();
	tls.close();
	condition.close();
	mutex.close();
	return 42;
}
