enum abstract Limb(Int) from Int to Int {
	var ArmL = 0;
	var ArmR = 1;
	var LegL = 2;
}

function pick(limb:Limb):Int
	return switch limb {
		case ArmL: 1;
		case ArmR: 20;
		default: 300;
	};

function main():Int {
	// Bare value names are constants, not bindings that catch every value.
	if (pick(ArmR) != 20 || pick(ArmL) != 1 || pick(LegL) != 300)
		return 1;
	var total = 0;
	var limb:Limb = LegL;
	switch limb {
		case ArmL:
			total = 100;
		case LegL:
			total = 20;
		default:
			total = 200;
	}
	// A lowercase name that is not a value still binds the subject.
	var seven:Limb = 7;
	var bound = switch seven {
		case other: other;
	};
	return total + bound + 15;
}
