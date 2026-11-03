interface Measured {
	function measure():Int;
}

struct ManagedPoint implements Measured {
	public var number:Int;
	public var label:String;
	public function new(number:Int, label:String) { this.number = number; this.label = label; }
	public function measure():Int return number + label.length;
}

struct ManagedOther {
	public var number:Int;
	public var label:String;
	public function new(number:Int, label:String) { this.number = number; this.label = label; }
}

class ReferenceValue {
	public var number:Int;
	public function new(number:Int) this.number = number;
}

function identity<T>(value:T):T return value;
function measure<T:Measured>(value:T):Int return value.measure();
function apply<T>(value:T, operation:T->Int):Int return operation(value);
function pointNumber(value:ManagedPoint):Int return value.number;

function main():Int {
	var point = new ManagedPoint(37, "hello");
	var copy = identity(point);
	copy.number = 7;
	var other = identity(new ManagedOther(9, "other"));
	var reference = identity(new ReferenceValue(3));
	return measure(point) == 42 && apply(point, pointNumber) == 37 && copy.number == 7 && point.number == 37 && other.number == 9
		&& other.label == "other" && reference.number == 3 ? 42 : 1;
}
