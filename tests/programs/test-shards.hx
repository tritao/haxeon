import haxeon.test.Shards;
import haxeon.test.Shards.TestGroup;

function expect(condition:Bool, message:String):Void {
	if (!condition)
		throw message;
}

function expectThrows(body:Void->Void, message:String):Void {
	var threw = false;
	try {
		body();
	} catch (_:Dynamic) {
		threw = true;
	}
	if (!threw)
		throw message;
}

function main():Int {
	var weights = [9.0, 1.0, 4.0, 1.0, 1.0, 7.0, 2.0, 2.0, 3.0, 1.0, 5.0, 1.0, 1.0, 1.0, 6.0];
	var groups:Array<TestGroup> = [
		for (index in 0...weights.length)
			{name: "group" + index, run: () -> {}, weight: weights[index]}
	];

	// Every group belongs to exactly one shard, for any number of shards, and the split is the same every time.
	for (count in 1...20) {
		var owned = new Map<String, Int>();
		var ownedCount = 0;
		for (shard in 1...count + 1) {
			var names = Shards.assignment(groups, shard, count);
			expect(names.join(",") == Shards.assignment(groups, shard, count).join(","), "the split is deterministic");
			var previous = -1;
			for (name in names) {
				expect(!owned.exists(name), "a group is in two shards");
				owned.set(name, shard);
				ownedCount++;
				var index = Std.parseInt(name.substr(5));
				expect(index > previous, "a shard keeps the groups in their listed order");
				previous = index;
			}
		}
		expect(ownedCount == groups.length, "a shard count left a group out");
	}

	// Heavy groups are spread: no shard carries more than an even share plus the heaviest group.
	var total = 0.0;
	for (weight in weights)
		total += weight;
	for (count in 2...6) {
		var heaviest = 0.0;
		for (shard in 1...count + 1) {
			var load = 0.0;
			for (name in Shards.assignment(groups, shard, count))
				load += weights[Std.parseInt(name.substr(5))];
			heaviest = Math.max(heaviest, load);
		}
		expect(heaviest <= total / count + 9.0, "a shard is overloaded");
	}

	// Groups without a weight count one each.
	var plain:Array<TestGroup> = [for (index in 0...6) {name: "plain" + index, run: () -> {}}];
	expect(Shards.assignment(plain, 1, 2).length == 3 && Shards.assignment(plain, 2, 2).length == 3, "unweighted groups split evenly");

	// `run` runs the shard's groups, in order, and says whether that was everything.
	var ran:Array<String> = [];
	var tracked:Array<TestGroup> = [
		for (index in 0...5)
			{name: "t" + index, run: () -> ran.push("t" + index), weight: 1.0}
	];
	expect(Shards.run(tracked, []) && ran.join(",") == "t0,t1,t2,t3,t4", "without a shard every group runs");
	ran = [];
	var partial = Shards.run(tracked, ["--shard", "1/2"]);
	var firstShard = ran.length;
	ran = [];
	var rest = Shards.run(tracked, ["--shard", "2/2"]);
	expect(!partial && !rest && firstShard + ran.length == 5, "two shards run every group once between them");

	var bad = [
		["--shard"],
		["--shard", "3/2"],
		["--shard", "0/2"],
		["--shard", "1"],
		["--shard", "a/b"],
		["--shard", "1/0"]
	];
	for (arguments in bad)
		expectThrows(() -> Shards.run(tracked, arguments), "a bad shard argument is rejected");
	expectThrows(() -> Shards.assignment([{name: "same", run: () -> {}}, {name: "same", run: () -> {}}], 1, 2), "two groups with one name are rejected");
	return 42;
}
