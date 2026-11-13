class CalledBase implements Observable {
	public var count:Int;
	public function new() {
		count = 1;
	}
}

class CalledModel extends CalledBase {
	public var label:String = "a";
}

// The copy is reached through a class that is observable by its base: the helper's callee is reached with it, and the copy is a separate object.
function main():Int {
	var model = new CalledModel();
	var copy:CalledModel = cast Reflect.copy(model);
	copy.count = 41;
	Reflect.setField(copy, "label", "b");
	return model.count + copy.count + (model.label == "a" && copy.label == "b" ? 0 : 100);
}
