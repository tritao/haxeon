// A generic method of a generic class is one specialization per layout of its owner as well as per its own type arguments: two
// receivers whose owner arguments differ but whose method arguments are the same must not share a body typed for one of them,
// erased (`Memo`, reached through a cast from `Memo<Dynamic>`), specialized (`Box` of an enum) or through a subclass (`Words`).
class Record<S, R> {
	final summaries:Array<Null<S>>;

	public final result:R;

	public function new(summaries:Array<Null<S>>, result:R) {
		this.summaries = summaries;
		this.result = result;
	}

	public function each(visit:(Int, S) -> Void):Void
		for (index in 0...summaries.length) {
			var summary = summaries[index];
			if (summary != null)
				visit(index, summary);
		}
}

class Memo<T> {
	final entries:Map<Int, Array<T>> = [];

	public function new() {}

	public function get(key:Int):Null<T> {
		var entry = entries.get(key);
		return entry == null ? null : entry[0];
	}

	public function keep(key:Int, value:T):Void
		entries.set(key, [value]);

	// A closure that takes the owner's parameter: once typed for one receiver's `T`, it cast the other's values to that `T`.
	public function takeBack<R>(record:Record<T, R>):R {
		record.each((key, summary) -> if (get(key) == null) keep(key, summary));
		return record.result;
	}

	public function takeBackHere<R>(record:Record<T, R>):R
		return takeBack(record);
}

class Walk {
	public final calls:Int;

	public function new(calls:Int)
		this.calls = calls;
}

class Escape {
	public final tags:Int;

	public function new(tags:Int)
		this.tags = tags;
}

enum Color {
	Red;
	Green(level:Int);
}

enum Shape {
	Circle(radius:Int);
	Square;
}

class Box<T> {
	public final items:Array<T> = [];

	public function new() {}

	public function addAll<R>(from:Array<T>, tag:R):R {
		for (item in from)
			items.push(item);
		return tag;
	}
}

class Words extends Box<String> {
	public function new()
		super();

	public function more<R>(tag:R):R
		return addAll(["more"], tag);
}

class Memos {
	final memos:Map<String, Memo<Dynamic>> = [];

	public function new() {}

	public function of<T>(name:String):Memo<T> {
		var memo = memos.get(name);
		if (memo == null) {
			memo = new Memo<Dynamic>();
			memos.set(name, memo);
		}
		return cast memo;
	}
}

function main():Int {
	var memos = new Memos(), walks:Memo<Walk> = memos.of("walks"), escapes:Memo<Escape> = memos.of("escapes");
	var walked = walks.takeBack(new Record<Walk, String>([new Walk(3), null], "walk"));
	var escaped = escapes.takeBack(new Record<Escape, String>([null, new Escape(4)], "escape"));
	escapes.takeBackHere(new Record<Escape, String>([new Escape(5), null], "again"));
	var walk = walks.get(0), escape = escapes.get(1), first = escapes.get(0);
	if (walked != "walk" || escaped != "escape" || walk == null || escape == null || first == null)
		return 1;
	var colors = new Box<Color>(), shapes = new Box<Shape>();
	colors.addAll([Green(6)], "colors");
	shapes.addAll([Circle(7)], "shapes");
	var words = new Words();
	words.addAll(["a"], 1);
	words.more(2);
	var level = switch colors.items[0] {
		case Green(level): level;
		case Red: 0;
	}, radius = switch shapes.items[0] {
		case Circle(radius): radius;
		case Square: 0;
	};
	return walk.calls + escape.tags + first.tags + level + radius + words.items.length + words.items[1].length + 11;
}
