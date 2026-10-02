// Reflect.compare as a sort comparator for several element types. For strings it is the runtime's
// __string_compare_full, a defined function whose table slot must survive the Math imports added beside it.
function main():Int {
	var names = ["delta", "alpha", "charlie", "bravo"];
	names.sort(Reflect.compare);
	var numbers = [3, 1, 2];
	numbers.sort(Reflect.compare);
	var dynamics:Array<Dynamic> = [3, 1, 2];
	dynamics.sort(Reflect.compare);
	var wave = Math.sin(0.0) + Math.cos(0.0) + Math.pow(2.0, 1.0);
	return names.join(",") == "alpha,bravo,charlie,delta"
		&& numbers.join(",") == "1,2,3"
		&& dynamics[0] == 1
		&& wave == 3.0 ? 42 : 1;
}
