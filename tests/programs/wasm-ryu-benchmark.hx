import runtime.Ryu;

function decimalChecksum(value:Float):Int {
	var decimal = Ryu.toDecimal(value);
	return haxe.Int64.toInt(decimal.significand) ^ decimal.exponent ^ decimal.kind;
}

function formatLength(value:Float):Int {
	var formatted = Ryu.format(value);
	return formatted.length;
}

function stdStringLength(value:Float):Int {
	var formatted = Std.string(value);
	return formatted.length;
}

function stdStringDynamicLength(value:Float):Int {
	var dynamicValue:Dynamic = value;
	return dynamicStringLength(dynamicValue);
}

function dynamicStringLength(value:Dynamic):Int {
	var formatted = Std.string(value);
	return formatted.length;
}

function main():Int {
	return 0;
}
