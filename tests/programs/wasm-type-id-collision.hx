// FNV-1a of Obj(CaxscQFXbw) and Obj(CVqowVrIwv) is 0xc9c551d1.
class CaxscQFXbw {
	public var left:Int;
	public function new(value:Int) left = value;
}

class CVqowVrIwv {
	public var right:String;
	public function new(value:String) right = value;
}

function main():Int {
	var first:Dynamic = new CaxscQFXbw(42), second:Dynamic = new CVqowVrIwv("kept");
	if (!Std.isOfType(first, CaxscQFXbw) || Std.isOfType(first, CVqowVrIwv)) return 1;
	if (!Std.isOfType(second, CVqowVrIwv) || Std.isOfType(second, CaxscQFXbw)) return 2;
	if (Reflect.field(first, "left") != 42 || Reflect.field(first, "right") != null) return 3;
	if (Reflect.field(second, "right") != "kept" || Reflect.field(second, "left") != null) return 4;
	var typed:Array<CaxscQFXbw> = [cast first], erased:Dynamic = typed, rejected = false;
	try { var wrong:Array<CVqowVrIwv> = cast erased; } catch (_:Dynamic) rejected = true;
	if (!rejected) return 5;
	var seed = 0;
	for (i in 0...3) seed += i;
	var retained = new CVqowVrIwv("retained-" + seed);
	for (i in 0...256) {
		var temporary = new CaxscQFXbw(i);
		if (temporary.left != i) return 6;
	}
	if (retained.right != "retained-3") return 7;
	return 42;
}
