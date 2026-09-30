interface Solver {
	function count():Int;
}

class Plain implements Solver {
	public function new() {}

	public function count():Int
		return 1;
}

class Special implements Solver {
	public function new() {}

	public function count():Int
		return 2;

	public function extra():Int
		return 40;
}

class SpecialChild extends Special {
	public function new() {
		super();
	}
}

function check(solver:Solver):Int {
	if (Std.isOfType(solver, Special)) {
		var special:Special = cast solver;
		return special.extra() + special.count();
	}
	return solver.count();
}

function main():Int {
	var plain:Solver = new Plain(),
		special:Solver = new Special(),
		child:Solver = new SpecialChild();
	if (Std.isOfType(plain, Special))
		return 1;
	if (!Std.isOfType(special, Special) || !Std.isOfType(special, Solver) || !Std.isOfType(plain, Solver))
		return 2;
	// A value typed as its class, and a subclass, pass an interface test too.
	var concrete = new SpecialChild();
	if (!Std.isOfType(concrete, Solver) || Std.isOfType("text", Solver) || Std.isOfType(null, Solver))
		return 6;
	if (!Std.isOfType(child, Special) || Std.isOfType(special, SpecialChild))
		return 3;
	if (!Std.isOfType(plain, Plain) || Std.isOfType(special, Plain))
		return 4;
	if (check(plain) != 1)
		return 5;
	return check(special);
}
