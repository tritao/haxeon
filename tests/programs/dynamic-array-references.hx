class Animal {
	public final name:String;

	public function new(name:String)
		this.name = name;
}

class Dog extends Animal {
	public function new(name:String)
		super(name);
}

class Cat extends Animal {
	public function new(name:String)
		super(name);
}

enum Shape {
	Circle(radius:Float);
	Square;
}

class Keep<T> {
	public final values:Array<T>;

	public function new(values:Array<T>)
		this.values = values;

	public function add(value:T):Void
		values.push(value);

	public function made():Array<T>
		return [for (value in values) value];
}

function fails(action:() -> Void, fragment:String):Bool {
	try
		action()
	catch (error:Dynamic)
		return Std.string(error).indexOf(fragment) >= 0;
	return false;
}

function main():Int {
	var animals:Array<Animal> = [new Dog("rex")];
	var keep = new Keep(animals);
	keep.add(new Cat("tom"));
	if (animals.length != 2 || animals[1].name != "tom")
		return 1;
	var dogs:Array<Dog> = [new Dog("a")];
	var dogView:Array<Dynamic> = cast dogs;
	if (!fails(() -> dogView.push(new Cat("c")), "") || dogs.length != 1)
		return 2;
	var mixed:Array<Dynamic> = [new Dog("d"), new Cat("e")];
	var asAnimals:Array<Animal> = cast mixed;
	if (asAnimals[1].name != "e")
		return 3;
	var notDogs:Array<Dynamic> = [new Dog("f"), new Cat("g")];
	if (!fails(() -> {
		var only:Array<Dog> = cast notDogs;
		only.push(new Dog("h"));
	}, "element 1 is Cat"))
		return 4;
	var shapes = [Circle(1.0), Square];
	var shapeKeep = new Keep(shapes);
	shapeKeep.add(Square);
	var madeShapes:Array<Shape> = shapeKeep.made();
	if (shapes.length != 3 || madeShapes.length != 3)
		return 5;
	switch madeShapes[0] {
		case Circle(radius) if (radius == 1.0):
		default:
			return 6;
	}
	var actions:Array<() -> Int> = [() -> 1];
	var actionKeep = new Keep(actions);
	actionKeep.add(() -> 2);
	if (actions[1]() != 2)
		return 7;
	var grid = [[1, 2], [3]];
	var gridKeep = new Keep(grid);
	gridKeep.add([4]);
	if (grid[2][0] != 4 || gridKeep.made()[1][0] != 3)
		return 8;
	var floatGrid:Array<Dynamic> = [[1.5]];
	var typedFloatGrid:Array<Array<Float>> = cast floatGrid;
	if (typedFloatGrid[0][0] != 1.5)
		return 9;
	return 42;
}
