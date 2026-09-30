// Field types are inferred from operator initializers that name static fields,
// including platform ones such as Math.PI, and fields of the same class by bare name.
class Counts {
	public static final STEPS:Int = 20;
}

class Units {
	public static final RADIAN = Math.PI / 180;
	public static final TURN = RADIAN * 360;
	public static final STEPS = Counts.STEPS * 2 + 1;
	public static final BACK = -Counts.STEPS;
}

function main():Int {
	var turn:Float = Units.TURN;
	var steps:Int = Units.STEPS + Units.BACK;
	if (Math.abs(turn - 2 * Math.PI) > 1.0e-12)
		return 1;
	if (steps != 21)
		return 2;
	return 42;
}
