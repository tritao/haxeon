package build.execution;

class ActionId {
	public final value:String;

	public function new(value:String) {
		if (value == null || value.length == 0)
			throw "ActionId cannot be empty";
		this.value = value;
	}

	public function key():String
		return value;

	public function toString():String
		return value;
}
