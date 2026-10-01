// A parameter or local named like a module function shadows it from its binding to the end of its block,
// and the function stays callable outside that scope.
function values(which:Int):Int
	return which;

function first(values:Array<Float>):Float {
	var copy = values;
	return copy[0] + values[0];
}

function later():Int {
	var before = values(3);
	var values = 2;
	return before + values;
}

function viaLambda():Int {
	var twice = (values:Int) -> values * 2;
	return twice(5) + values(1);
}

function inLoop():Int {
	var total = 0;
	for (values in [1, 2])
		total += values;
	return total + values(10);
}

function caught():Int {
	var length = 0;
	try {
		throw "xy";
	} catch (values:String) {
		length = values.length;
	}
	return length + values(0);
}

function comprehended():Int {
	var doubled = [for (values in 0...3) values * 2];
	return doubled[2] + values(100);
}

function blockValue():Int {
	var result = {
		var values = 7;
		values + 1;
	};
	return result + values(1000);
}

function main():Int {
	if (first([2.5]) != 5.0 || later() != 5 || viaLambda() != 11 || inLoop() != 13 || caught() != 2 || comprehended() != 104 || blockValue() != 1008)
		return 1;
	return 42;
}
