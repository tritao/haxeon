class UncopiedBase implements Observable {
	public var count:Int;
	public function new() {
		count = 1;
	}
}

class UncopiedModel extends UncopiedBase {
	public var label:String = "a";
}

// Observable classes (one through its base) are in the program and reached code reflects, but calls field and setField but never copy: the copy
// helper is not reached, so neither it nor the creation hook it calls may be generated.
function unusedModel(model:UncopiedModel):Int
	return model.count;

function main():Int {
	var raw:Dynamic = {total: 40};
	Reflect.setField(raw, "total", 40);
	var total:Int = Reflect.field(raw, "total");
	return total + 2;
}
