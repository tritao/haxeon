import runtime.Ryu;
import runtime.FloatBits;

#if wasm
function decimalMatches(value:Float, significand:Int, exponent:Int):Bool {
	var decimal = Ryu.toDecimal(value);
	return decimal.kind == 0
		&& decimal.exponent == exponent
		&& haxe.Int64.compare(decimal.significand, haxe.Int64.make(0, significand)) == 0;
}
#end

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
	#if wasm
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
	#else
	var shortestCommonValues = true;
	var commonLayouts = true;
	#end
	var dynamicDispatch = runtimeString(1.0) == "1"
		&& runtimeString(fixedLarge) == "100000000000000000000"
		&& runtimeString(scientificSmall) == "1e-7"
		&& runtimeString(42) == "42"
		&& runtimeString("text") == "text";
	var dynamicValue:Dynamic = fixedLarge;
	var stringConcatenation = fixedLarge + "!" == "100000000000000000000!"
		&& scientificSmall + "!" == "1e-7!"
		&& dynamicValue + "!" == "100000000000000000000!";
	var parityValues = [
		12.7,
		6.35,
		0.1 + 0.2,
		20.0,
		1e21,
		1e-7,
		smallestSubnormal,
		largestFinite,
		-0.0,
		1.0 / 0.0,
		-1.0 / 0.0,
		0.0 / 0.0
	];
	var parityText = [
		"12.7",
		"6.35",
		"0.30000000000000004",
		"20",
		"1e+21",
		"1e-7",
		"5e-324",
		"1.7976931348623157e+308",
		"0",
		"Infinity",
		"-Infinity",
		"NaN"
	];
	var parity = true;
	for (index in 0...parityValues.length)
		parity = parity && Std.string(parityValues[index]) == parityText[index];
	parity = parity && '${12.7}' == "12.7" && 'value ${6.35}' == "value 6.35";
	parity = parity && haxe.Json.stringify(12.7) == "12.7";
	parity = parity && haxe.Json.stringify([12.7, 0.1 + 0.2]) == "[12.7,0.30000000000000004]";
	#if !wasm
	parity = parity && haxe.Json.stringify({a: 12.7, b: 0.1 + 0.2}) == '{"a":12.7,"b":0.30000000000000004}';
	var bits:haxe.Int64 = haxe.Int64.make(0x9e3779b9, 0x7f4a7c15);
	for (_ in 0...10000) {
		bits = bits ^ (bits << 13);
		bits = bits ^ (bits >>> 7);
		bits = bits ^ (bits << 17);
		var value = FloatBits.fromInt64(bits);
		if (Math.isFinite(value))
			parity = parity && Std.parseFloat(Std.string(value)) == value;
	}
	#end
	return shortestCommonValues && commonLayouts && dynamicDispatch && stringConcatenation && parity ? 42 : 0;
}
