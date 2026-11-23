# Iteration

Use `for (value in source)` to visit successive values. The range `0...2` stops before 2.
Use `for (key => value in source)` when you need both parts. For an array the key is the index.

You can loop directly over an object with `hasNext():Bool` and `next():T`, as with `Countdown`. To make a
collection you can traverse from the beginning each time, give it an `iterator()` method that returns a fresh
iterator.

```haxe
class Countdown {
	var remaining:Int;

	public function new(start:Int) {
		remaining = start;
	}

	public function hasNext():Bool {
		return remaining > 0;
	}

	public function next():Int {
		return remaining--;
	}
}

function main():Void {
	for (i in 0...2)
		Sys.println(i);
	for (index => fruit in ["pear", "plum"])
		Sys.println('$index: $fruit');
	for (number in new Countdown(2))
		Sys.println('T-$number');
}
```

```text title="Output"
0
1
0: pear
1: plum
T-2
T-1
```

[Example project](examples/iteration/)

[Iteration reference](../reference/ITERATION.md)
