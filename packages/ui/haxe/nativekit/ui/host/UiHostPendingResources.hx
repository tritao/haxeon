package nativekit.ui.host;

/** Cancellation-aware request table used during asynchronous host startup. */
class UiHostPendingResources<T> {
	final values:Map<String, T> = new Map();
	var active:Bool = true;
	public var remaining(default, null):Int = 0;

	public function new() {}

	public function add(key:String, value:T):Void {
		if (!active) return;
		if (!values.exists(key)) remaining++;
		values.set(key, value);
	}

	public function resolve(key:String):Null<T> {
		if (!active) return null;
		var value = values.get(key);
		if (value != null) {
			values.remove(key);
			remaining--;
		}
		return value;
	}

	public function cancel():Void {
		if (!active) return;
		active = false;
		values.clear();
		remaining = 0;
	}
}
