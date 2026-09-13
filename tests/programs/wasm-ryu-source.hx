import runtime.Ryu;
import runtime.FloatBits;

function decimalMatches(value:Float, significand:Int, exponent:Int):Bool {
	var decimal = Ryu.toDecimal(value);
	return decimal.kind == 0
		&& decimal.exponent == exponent
		&& haxe.Int64.compare(decimal.significand, haxe.Int64.make(0, significand)) == 0;
}

function runtimeString(value:Dynamic):String {
	return Std.string(value);
}

function stringifyFloat(value:Float):String {
	return Std.string(value);
}

function main():Int {
	var fixedLarge = 100000000000000000000.0;
	var scientificLarge = 1000000000000000000000.0;
	var fixedSmall = 0.000001;
	var scientificSmall = 0.0000001;
	var smallestSubnormal = FloatBits.fromInt64(haxe.Int64.make(0, 1));
	var largestFinite = FloatBits.fromInt64(haxe.Int64.make(0x7fefffff, -1));
	var subnormalDecimal = Ryu.toDecimal(smallestSubnormal);
	var shortestCommonValues = decimalMatches(1.0, 1, 0)
		&& decimalMatches(0.1, 1, -1)
		&& decimalMatches(1.5, 15, -1)
		&& decimalMatches(fixedLarge, 1, 20)
		&& decimalMatches(scientificSmall, 1, -7)
		&& subnormalDecimal.kind == 0
		&& subnormalDecimal.exponent == -324
		&& haxe.Int64.compare(subnormalDecimal.significand, haxe.Int64.make(0, 5)) == 0;
	var commonLayouts = Ryu.format(1.0) == "1"
		&& Ryu.format(-0.1) == "-0.1"
		&& Ryu.format(0.1) == "0.1"
		&& Ryu.format(1.5) == "1.5"
		&& Ryu.format(fixedLarge) == "100000000000000000000"
		&& Ryu.format(scientificLarge) == "1e+21"
		&& Ryu.format(fixedSmall) == "0.000001"
		&& Ryu.format(scientificSmall) == "1e-7"
		&& stringifyFloat(fixedLarge) == "100000000000000000000"
		&& Ryu.format(smallestSubnormal) == "5e-324"
		&& Ryu.format(largestFinite) == "1.7976931348623157e+308"
		&& Ryu.format(-0.0) == "0"
		&& Ryu.format(1.0 / 0.0) == "Infinity"
		&& Ryu.format(-1.0 / 0.0) == "-Infinity"
		&& Ryu.format(0.0 / 0.0) == "NaN";
	var dynamicDispatch = runtimeString(1.0) == "1"
		&& runtimeString(fixedLarge) == "100000000000000000000"
		&& runtimeString(scientificSmall) == "1e-7"
		&& runtimeString(42) == "42"
		&& runtimeString("text") == "text";
	var dynamicValue:Dynamic = fixedLarge;
	var stringConcatenation = fixedLarge + "!" == "100000000000000000000!"
		&& scientificSmall + "!" == "1e-7!"
		&& dynamicValue + "!" == "100000000000000000000!";
	return shortestCommonValues && commonLayouts && dynamicDispatch && stringConcatenation ? 42 : 0;
}
