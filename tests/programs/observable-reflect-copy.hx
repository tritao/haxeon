class CopiedBase implements Observable {
	public var count:Int;
	public function new() {
		count = 1;
	}
}

class CopiedModel extends CopiedBase {
	public var label:String = "a";
}

// Observable classes (one through its base) are in the program and reached code reflects, but calls only Reflect.field: the set, delete and
// copy helpers are never reached, so neither they nor what they call (the write-status check, the creation hook) may be generated.
function unusedModel(model:CopiedModel):Int
	return model.count;

function main():Int {
	var raw:Dynamic = {total: 40};
	var total:Int = Reflect.field(raw, "total");
	return total + 2;
}
