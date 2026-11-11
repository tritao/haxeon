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

	// `--only` runs the named groups in their listed order; `*` matches any run of characters.
	expect(Shards.matches("t*", "t3") && Shards.matches("*3", "t3") && Shards.matches("t*3", "t3") && Shards.matches("*", "x"), "wildcards match");
	expect(!Shards.matches("t", "t3") && !Shards.matches("t*4", "t3") && !Shards.matches("a*b*c", "abxc0"), "wildcards do not over-match");
	expect(Shards.matches("ab*b", "abb") && !Shards.matches("ab*ab", "ab"), "a wildcard does not reuse the prefix");
	ran = [];
	expect(!Shards.run(tracked, ["--only", "t3,t1"]) && ran.join(",") == "t1,t3", "--only runs named groups in listed order");
	ran = [];
	expect(!Shards.run(tracked, ["--only", "t*"]) && ran.length == 5, "--only with a wildcard");
	ran = [];
	Shards.run(tracked, ["--shard", "1/2", "--only", "t*"]);
	expect(ran.length == firstShard, "--only within a shard keeps to the shard");
	expectThrows(() -> Shards.run(tracked, ["--only", "t1,missing"]), "a pattern naming no group is rejected");
	expectThrows(() -> Shards.run(tracked, ["--only"]), "--only needs names");
	expectThrows(() -> Shards.run(tracked, ["--only", ""]), "an empty pattern is rejected");

	// `--list` names the selected groups and runs none of them.
	ran = [];
	expect(!Shards.run(tracked, ["--list", "--only", "t2"]) && ran.length == 0, "--list runs nothing");

	// `--keep-going` runs every selected group past failures and reports all of them.
	ran = [];
	var failing:Array<TestGroup> = [
		{name: "ok1", run: () -> ran.push("ok1")},
		{name: "bad1", run: () -> throw "first"},
		{name: "ok2", run: () -> ran.push("ok2")},
		{name: "bad2", run: () -> throw "second"}
	];
	var report = "";
	try
		Shards.run(failing, ["--keep-going"])
	catch (error:Dynamic)
		report = Std.string(error);
	expect(ran.join(",") == "ok1,ok2", "groups after a failure still run");
	expect(report.indexOf("2 of 4 groups failed") >= 0 && report.indexOf("bad1, bad2") >= 0, "every failure is reported: " + report);
	ran = [];
	expectThrows(() -> Shards.run(failing, []), "without --keep-going the first failure stops the run");
	expect(ran.join(",") == "ok1", "without --keep-going later groups do not run");
	return 42;
}
