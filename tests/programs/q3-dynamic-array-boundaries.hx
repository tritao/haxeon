class Q3Animal { public function new() {} }
class Q3Dog extends Q3Animal { public function new() super(); }
class Q3Cat extends Q3Animal { public function new() super(); }

enum Q3Value implements Equatable { Item(value:Int); }

function main():Int {
	var values:Array<Q3Value> = [Item(1), Item(2)];
	var view:Array<Dynamic> = cast values;
	view[1] = Item(3);
	if (values[1] != Item(3)) return 1;
	values.push(Item(4));
	if (view.length != 3 || !(view[2] == Item(4))) return 2;
	var failed = false;
	try { view.push("wrong"); } catch (_:Dynamic) failed = true;
	if (!failed || values.length != 3) return 3;
	var dogs:Array<Q3Dog> = [new Q3Dog()];
	var dogView:Array<Dynamic> = cast dogs;
	failed = false;
	try { dogView.push(new Q3Cat()); } catch (_:Dynamic) failed = true;
	if (!failed || dogs.length != 1) return 4;
	var mixed:Array<Dynamic> = [new Q3Dog(), new Q3Cat()];
	failed = false;
	try { var onlyDogs:Array<Q3Dog> = cast mixed; onlyDogs.push(new Q3Dog()); } catch (_:Dynamic) failed = true;
	if (!failed || mixed.length != 2) return 5;
	return 42;
}
