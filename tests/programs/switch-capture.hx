// `name = pattern` matches what `pattern` matches and binds the matched value: a whole case, an enum payload or an array
// element. A capture over alternatives binds whichever one matched. The pattern of `.match` binds none, as in Haxe.
enum Shape {
	Circle(radius:Int);
	Rect(width:Int, height:Int);
	Group(first:Shape, rest:Array<Shape>);
}

enum abstract Mode(Int) {
	var Fast = 1;
	var Slow = 2;
	var Off = 3;
}

function measure(shape:Shape):Int
	return switch shape {
		case Circle(r): r;
		case Rect(w, h): w * h;
		case Group(_, rest): rest.length;
	};

function lead(shape:Shape):Int
	return switch shape {
		case Group(inner = Circle(_), _): measure(inner);
		case Group(inner = Rect(_, 4) | Rect(4, _), rest): rest.length * 100 + measure(inner);
		case Group(_, _): 0;
		case whole = Rect(w, 1): w + measure(whole) * 10;
		case Circle(_) | Rect(_, _): -1;
	};

function speed(mode:Mode):Int
	return switch mode {
		case moving = Fast | Slow: moving == Fast ? 1 : 2;
		case Off: 0;
	};

function size(n:Int):Int {
	switch n {
		case small = 1 | 2 | 3:
			return small;
		case big:
			return big * 10;
	}
}

function pair(values:Array<Int>):Int
	return switch values {
		case [first = 1, second]: first + second;
		case all = [_, _]: all.length;
		default: 0;
	};

function main():Int {
	if (lead(Group(Circle(2), [])) != 2)
		return 1;
	if (lead(Group(Rect(3, 4), [Circle(1)])) != 112 || lead(Group(Rect(3, 5), [])) != 0)
		return 2;
	if (lead(Rect(5, 1)) != 55 || lead(Rect(5, 2)) != -1)
		return 3;
	if (speed(Fast) != 1 || speed(Slow) != 2 || speed(Off) != 0)
		return 4;
	if (size(2) != 2 || size(9) != 90)
		return 5;
	if (pair([1, 7]) != 8 || pair([4, 5]) != 2 || pair([4]) != 0)
		return 6;
	if (!Group(Circle(1), []).match(Group(Circle(_), _)) || Circle(1).match(Rect(_, _)))
		return 7;
	return 42;
}
