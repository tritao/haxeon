// A Dynamic array index, as an untyped `cast` gives, unifies with Int: it reads, stores and updates the element.
enum abstract Op(Int) {
	var A = 0;
	var B = 1;
}

class Main {
	static function main() {
		var names = ["A", "B"], op = B;
		Sys.println(names[cast op]);
		names[cast A] = "Z";
		var d:Dynamic = 1;
		Sys.println(names[d]);
		names[d] = "C";
		names[d] += "!";
		Sys.println(names);
		var counts = [10, 20];
		counts[cast op]++;
		Sys.println(counts);
	}
}
