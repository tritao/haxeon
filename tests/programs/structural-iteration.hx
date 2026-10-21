class Counter {
	public static function version():Int
		return 4;

	public var position:Int;

	public function new() {
		position = 0;
	}

	public function hasNext():Bool {
		return position < 4;
	}

	public function next():Int {
		return ++position;
	}
}

class Collection {
	public function new() {}

	public function iterator():Counter {
		return new Counter();
	}
}

function sum(values:Iterable<Int>):Int {
	var result = 0;
	for (value in values)
		result += value;
	return result;
}

class GenericIterator<T> {
	public var values:Array<T>;
	public var index:Int;

	public function new(values:Array<T>) {
		this.values = values;
		index = 0;
	}

	public function hasNext():Bool
		return index < values.length;

	public function next():T
		return values[index++];
}

class InheritedIterator extends Counter {
	public function new() {
		super();
	}
}

class Stored {
	public var values:Iterable<Int>;

	public function new(values:Iterable<Int>) {
		this.values = values;
	}

	public function iterator():Iterator<Int>
		return values.iterator();
}

@:noInline function concreteLoop(values:Counter):Int {
	var result = 0;
	for (value in values)
		result += value;
	return result;
}

@:noInline function arrayHelper<T>(values:Iterable<T>):Int {
	var result = 0;
	for (value in values)
		result++;
	return result;
}

function fold<T>(values:Iterable<T>, transform:T->Int):Int {
	var result = 0;
	for (value in values)
		result += transform(value);
	return result;
}

class GenericFields<T> {
	public var hasNext:() -> Bool;
	public var next:() -> T;

	public function new(values:Array<T>) {
		var index = 0;
		hasNext = () -> index < values.length;
		next = () -> values[index++];
	}
}

interface NamedIterator {
	public function hasNext():Bool;
	public function next():Int;
}

class NamedCounter extends Counter implements NamedIterator {
	public function new() {
		super();
	}
}

function interfaceLoop(values:NamedIterator):Int {
	var result = 0;
	for (x in values)
		result += x;
	return result;
}

function reassign<T>(values:Iterable<T>, replacement:Iterable<T>):Int {
	var copy = values;
	copy = replacement;
	return Lambda.count(copy);
}

function storedAlias<T>(values:Iterable<T>, replacement:Iterable<T>):Int {
	var state = {values: values};
	state.values = replacement;
	return Lambda.count(state.values);
}

function rebind<T>(values:Iterable<T>, replacement:Iterable<T>):Int {
	values = replacement;
	return Lambda.count(values);
}

typedef ReadonlyIterator = {final hasNext:() -> Bool; final next:() -> Int;};

function acceptReadonly(it:ReadonlyIterator):Int
	return it.next();

function optionalPair<T>(first:Iterable<Int>, second:Iterable<Int>, unused:T):Int {
	if (first != null)
		return Lambda.count(first);
	if (second != null)
		return Lambda.count(second);
	return 0;
}

function main():Int {
	var total = 0;
	for (value in new Counter())
		total += value;
	for (value in new Collection())
		total += value;
	var map:Map<String, Int> = ["a" => 2, "b" => 4];
	if (Lambda.count(map) != 2 || Lambda.count(map, x -> x > 2) != 1)
		return 1;
	if (!Lambda.has(map, 4) || !Lambda.exists(new Collection(), x -> x == 3))
		return 2;
	if (Lambda.find(new Collection(), x -> x > 2) != 3)
		return 3;
	var a = [for (x in new Collection()) if (x > 1) x * 2];
	var b = [for (x in new Counter()) x => x * 3];
	if (a.length != 3 || a[0] != 4 || b.get(4) != 12)
		return 4;
	var it:Iterator<Int> = new Counter();
	if (!it.hasNext() || it.next() != 1)
		return 5;
	if (Lambda.count([1, 2, 3]) != 3 || Lambda.count([1, 2, 3], x -> x > 1) != 2)
		return 6;
	if (Lambda.count(new Collection()) != 4 || arrayHelper([1, 2, 3]) != 3)
		return 7;
	if (concreteLoop(new Counter()) != 10 || fold(new Collection(), x -> x * 2) != 20)
		return 8;
	var native:Iterator<Int> = [2, 3].iterator();
	var nativeSum = 0;
	for (x in native)
		nativeSum += x;
	if (nativeSum != 5)
		return 9;
	var factoryCalls = 0;
	var iteratorCalls = 0;
	var collection = {
		iterator: function() {
			iteratorCalls++;
			return new Counter();
		}
	};
	var factory = function() {
		factoryCalls++;
		return collection;
	};
	var once = 0;
	for (x in factory()) {
		if (x == 2)
			continue;
		once += x;
		if (x == 3)
			break;
	}
	if (factoryCalls != 1 || iteratorCalls != 1 || once != 4)
		return 10;
	var n = 0;
	var anonymous = {hasNext: function() return n < 3, next: function() return ++n};
	var anonymousSum = 0;
	for (x in anonymous)
		anonymousSum += x;
	if (anonymousSum != 6)
		return 11;
	var inherited = [for (x in new InheritedIterator()) x];
	var generic = [for (x in new GenericIterator<String>(["a", "bb"])) x.length];
	if (inherited.length != 4 || generic[1] != 2)
		return 12;
	var nested = [
		for (x in new Collection())
			for (y in new Collection())
				if (x == y)
					x + y
	];
	if (nested.length != 4 || nested[3] != 8)
		return 13;
	var funcs:Array<() -> Int> = [];
	for (x in new Counter())
		funcs.push(() -> x);
	if (funcs[0]() != 1 || funcs[3]() != 4)
		return 14;
	var stored = new Stored(new Collection());
	if (sum(stored) != 10)
		return 15;
	var heterogeneous:Array<Iterable<Int>> = [[1, 2], new Collection()];
	if (sum(heterogeneous[0]) + sum(heterogeneous[1]) != 13)
		return 16;
	if (!Lambda.has(["one", "two"], "two") || Lambda.find(["one", "two"], x -> x.length == 3) != "one")
		return 17;
	if (reassign([1], new Collection()) != 4 || rebind([1], new Collection()) != 4 || storedAlias([1], new Collection()) != 4)
		return 18;
	var fieldValues = [for (x in new GenericFields<String>(["a", "bb"])) x.length];
	if (fieldValues[1] != 2 || interfaceLoop(new NamedCounter()) != 10)
		return 19;
	var strings:Map<Int, String> = [1 => "a", 2 => "bb"];
	if (!Lambda.has(strings, "bb") || Lambda.count(strings, x -> x.length == 1) != 1)
		return 20;
	var mutations:Map<String, Int> = ["a" => 1, "b" => 2];
	if (Lambda.count(mutations, x -> {
		mutations.remove("a");
		mutations.remove("b");
		return true;
	}) != 2)
		return 21;
	if (optionalPair(null, [1, 2], 0) != 2 || optionalPair([1], null, 0) != 1)
		return 22;
	var readonly:ReadonlyIterator = {hasNext: () -> true, next: () -> 9};
	var structural:Iterator<Int> = readonly;
	if (acceptReadonly(structural) != 9)
		return 23;
	return total + sum(new Collection()) + sum([5, 7]) + Counter.version() - 4;
}
