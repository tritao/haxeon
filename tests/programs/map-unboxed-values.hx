/** Maps keep Int, Bool, Float and Int64 values unboxed, and a map of maps keeps each inner map as it is. */
class Holder {
	public var byName:Map<String, Map<String, Int>> = new Map();

	public function new() {}
}

function main():Int {
	var outer:Map<Int, Map<String, Int>> = new Map();
	for (i in 0...5) {
		var inner:Map<String, Int> = new Map();
		inner.set("v", i * 10);
		inner.set("big", 100000 + i);
		outer.set(i, inner);
	}
	var total = 0;
	for (k => m in outer)
		total += (m.get("v") ?? 0) + k;
	for (m in outer)
		total += (m.get("big") ?? 0) - 100000;
	if (total != 120) return 1;
	if (outer.get(99) != null) return 2;
	var got = outer.get(3);
	if (got == null || got.get("v") != 30) return 3;
	var handle:Dynamic = outer.get(2);
	if (handle == null) return 4;
	var copy = outer.copy();
	outer.remove(1);
	if (copy.get(1) == null || outer.exists(1)) return 5;
	var holder = new Holder();
	holder.byName.set("x", got);
	var listed = [for (m in holder.byName) m];
	if (listed.length != 1 || listed[0].get("big") != 100003) return 6;
	var flags:Map<String, Bool> = ["a" => true, "b" => false];
	if (flags.get("a") != true || flags.get("b") != false || flags.get("c") != null) return 7;
	var fractions:Map<Int, Float> = [1 => 1.5, 2 => -0.25];
	var sum = 0.0;
	for (v in fractions)
		sum += v;
	if (sum != 1.25 || fractions.get(3) != null) return 8;
	var wide:Map<String, haxe.Int64> = new Map();
	wide.set("k", haxe.Int64.make(1, 2));
	if (wide.get("k") != haxe.Int64.make(1, 2) || wide.get("missing") != null) return 9;
	var counts:Map<String, Int> = new Map();
	for (word in ["a", "b", "a", "c", "a"]) {
		var count = counts.get(word);
		counts.set(word, count == null ? 1 : count + 1);
	}
	if (counts.get("a") != 3 || counts["b"] != 1) return 10;
	var values = [for (v in counts) v];
	values.sort(Reflect.compare);
	if (values.join(",") != "1,1,3") return 11;
	counts.remove("a");
	if (counts.get("a") != null || counts.exists("a") || [for (k in counts.keys()) k].length != 2) return 12;
	return 42;
}
