// Lambda.count counts every value, or only those a predicate accepts.
function main():Int {
	var values = [3, 8, 5, 12, 7];
	var all = Lambda.count(values);
	var big = Lambda.count(values, value -> value > 6);
	var none = Lambda.count(values, value -> value > 100);
	var nothing:Array<Int> = [];
	var empty = Lambda.count(nothing);
	return all == 5 && big == 3 && none == 0 && empty == 0 ? 42 : 1;
}
