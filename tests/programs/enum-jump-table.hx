// A switch whose arms only name constructors is a jump table on the constructor index (IrTerminator.Switch, OSwitch on
// HashLink): a constructor no arm names goes to the default, a catch-all takes the rest, an expression without a default takes
// its last arm for what the others leave, and a case that continues the loop around it jumps back through the table.
enum Op {
	Add;
	Sub;
	Mul;
	Div;
	Neg;
	Load(slot:Int);
	Store(slot:Int);
	Halt;
}

@:noInline function cost(op:Op):Int {
	switch op {
		case Add, Sub:
			return 1;
		case Mul:
			return 3;
		case Load(slot):
			return 10 + slot;
		default:
			return -1;
	}
}

@:noInline function name(op:Op):String
	return switch op {
		case Add: "add";
		case Sub: "sub";
		case Mul: "mul";
		case Div: "div";
		case Neg: "neg";
		case Load(_): "load";
		case Store(_): "store";
		case Halt: "halt";
	};

@:noInline function arity(op:Op):Int
	return switch op {
		case Add | Sub | Mul | Div: 2;
		case Neg: 1;
		case other: other == Halt ? 0 : 1;
	};

@:noInline function run(program:Array<Op>):Int {
	var stack:Array<Int> = [], slots = [0, 0, 0, 0], pc = 0, steps = 0;
	while (pc < program.length) {
		var op = program[pc++];
		steps++;
		switch op {
			case Halt:
				break;
			case Load(slot):
				stack.push(slots[slot]);
				continue;
			case Store(slot):
				slots[slot] = (stack.pop() ?? 0);
				continue;
			case Neg:
				stack.push(-(stack.pop() ?? 0));
			case Add:
				stack.push((stack.pop() ?? 0) + (stack.pop() ?? 0));
			case Sub:
				var right = (stack.pop() ?? 0);
				stack.push((stack.pop() ?? 0) - right);
			case Mul:
				stack.push((stack.pop() ?? 0) * (stack.pop() ?? 0));
			case Div:
				var right = (stack.pop() ?? 0);
				stack.push(Std.int((stack.pop() ?? 0) / right));
		}
	}
	return slots[0] * 100 + steps;
}

function main():Int {
	var all = [Add, Sub, Mul, Div, Neg, Load(2), Store(1), Halt];
	var checks = [[for (op in all) cost(op)].join(",") == "1,1,3,-1,-1,12,-1,-1",
		[for (op in all) name(op)].join(",") == "add,sub,mul,div,neg,load,store,halt",
		[for (op in all) arity(op)].join(",") == "2,2,2,2,1,1,1,0",
		run([Load(1), Load(2), Add, Neg, Store(0), Halt, Load(3)]) == 6,
		{var slots = [Load(0), Load(0), Mul, Store(0), Halt];
	run(slots) == 5;
	}];
	for (index in 0...checks.length)
		if (!checks[index])
			return 100 + index;
	return 42;
}
