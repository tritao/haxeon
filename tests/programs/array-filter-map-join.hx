class Point {
	public final x:Int;

	public function new(x:Int)
		this.x = x;
}

function isEven(value:Int):Bool
	return value % 2 == 0;

function main():Int {
	var values = [1, 2, 3, 4, 5, 6];
	var evens = values.filter(value -> value % 2 == 0);
	if (evens.length != 3 || evens[0] != 2 || evens[2] != 6)
		return 1;
	var named = values.filter(isEven);
	if (named.length != 3 || named[1] != 4)
		return 2;
	var doubled = values.map(value -> value * 2);
	if (doubled.length != 6 || doubled[5] != 12)
		return 3;
	var labels = values.map(value -> 'v$value');
	if (labels.join(",") != "v1,v2,v3,v4,v5,v6")
		return 4;
	if (values.join("-") != "1-2-3-4-5-6" || [1.5, 2.0].join(";") != "1.5;2")
		return 5;
	var points = values.map(value -> new Point(value));
	var large = points.filter(point -> point.x > 3).map(point -> point.x);
	if (large.join(",") != "4,5,6")
		return 6;
	var scale = 10;
	var scaler = function(value:Int):Int return value * scale;
	var scaled = values.map(scaler);
	if (scaled[0] != 10 || scaled[5] != 60)
		return 7;
	var evaluations = 0;
	var counted = values.filter(function(value) {
		evaluations++;
		return value > 4;
	});
	if (counted.length != 2 || evaluations != 6)
		return 8;
	var nested = [[1, 2], [3]].map(row -> row.map(value -> value + 1).join("+"));
	if (nested.join("|") != "2+3|4")
		return 9;
	var none:Array<Int> = [];
	if (none.filter(value -> value > 0).length != 0 || none.map(value -> value).length != 0)
		return 10;
	return 42;
}
