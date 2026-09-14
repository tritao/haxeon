import runtime.Ryu;

function decimalChecksum(value:Float):Int {
	var decimal = Ryu.toDecimal(value);
	return haxe.Int64.toInt(decimal.significand) ^ decimal.exponent ^ decimal.kind;
}

function stringifyFloat(value:Float):String {
	return Ryu.format(value);
}

function main():Int {
	return 0;
}
