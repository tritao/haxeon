class Axis {
	public final value:Int;

	public function new(value:Int)
		this.value = value;
}

// A generic class keeps comparison functions typed by its parameter; its statics compare
// concrete types and are stored into that field, as UIKit's StyleProperty does.
class Property<T> {
	public final name:String;

	final equalValue:Null<(T, T) -> Bool>;
	final read:Axis->T;

	public function new(name:String, read:Axis->T, ?equalValue:(T, T) -> Bool) {
		this.name = name;
		this.read = read;
		this.equalValue = equalValue;
	}

	public function isEqual(left:T, right:T):Bool
		return equalValue == null ? left == right : equalValue(left, right);

	public function same(left:Axis, right:Axis):Bool
		return isEqual(read(left), read(right));

	static function axisEqual(left:Axis, right:Axis):Bool
		return left == right || (left != null && right != null && left.value == right.value);

	static function floatEqual(left:Float, right:Float):Bool
		return Math.abs(left - right) < 0.5;

	public static final Self:Property<Axis> = new Property("self", axis -> axis, axisEqual);
	public static final Scaled:Property<Float> = new Property("scaled", axis -> axis.value * 1.0, floatEqual);
	public static final Identity:Property<Axis> = new Property("identity", axis -> axis);
	public static final Count:Property<Int> = new Property("count", axis -> axis.value, (left, right) -> left == right);
}

function main():Int {
	var one = new Axis(1), alsoOne = new Axis(1), two = new Axis(2);
	if (!Property.Self.same(one, alsoOne) || Property.Self.same(one, two))
		return 1;
	if (!Property.Scaled.same(one, alsoOne) || Property.Scaled.same(one, two))
		return 2;
	if (!Property.Identity.same(one, one) || Property.Identity.same(one, alsoOne))
		return 3;
	if (!Property.Count.same(one, alsoOne) || Property.Count.same(one, two))
		return 4;
	var all:Array<Dynamic> = [Property.Self, Property.Scaled, Property.Identity, Property.Count];
	var matches = 0;
	for (property in all) {
		var typed:Property<Dynamic> = property;
		if (typed.same(one, alsoOne))
			matches++;
	}
	return matches == 3 ? 42 : 5;
}
