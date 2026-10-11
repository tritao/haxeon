package haxeon.ui.properties;

/** One-shot completion delivered by the application on its UI thread.
 * A queued operation is not an applied edit. The owner resolves this after
 * its transaction commits or fails, including cancellation on disposal.
 */
class PropertyPendingEdit {
	public var result(default, null):Null<PropertyEditResult> = null;
	final listeners:Array<PropertyEditResult->Void> = [];
	public function new() {}
	public function onComplete(listener:PropertyEditResult->Void):Void {
		if (result == null) listeners.push(listener); else listener(result);
	}
	public function resolve(next:PropertyEditResult):Void {
		if (next == null) throw "A terminal property result is required";
		switch next { case Pending(_): throw "Completion cannot be pending"; default: }
		if (result != null) throw "Property edit already completed";
		result = next;
		var callbacks = listeners.copy(); listeners.resize(0);
		for (callback in callbacks) callback(next);
	}
}
