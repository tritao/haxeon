import compiler.backend.wasm.WasmTypeIdPlan;
import compiler.ir.Ir.IrType;
import compiler.ir.IrTypeIdentity;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.wasm.WasmPatch;

class WasmTypeIdPlanMain {
	static function main():Void run();

	public static function run():Void {
		var a:IrType = Obj("CaxscQFXbw"), b:IrType = Obj("CVqowVrIwv");
		if (IrTypeIdentity.id(a) != IrTypeIdentity.id(b)) throw "collision fixture no longer collides";
		var first = new WasmTypeIdPlan([a, b, Bytes, Array(Dyn)]), reversed = new WasmTypeIdPlan([Array(Dyn), Bytes, b, a]);
		if (first.id(a) == first.id(b)) throw "colliding runtime types share an ID";
		if (first.id(a) != reversed.id(a) || first.id(b) != reversed.id(b)) throw "type IDs depend on collection order";
		if (first.remapped().length != 1 || !first.compatibleWith(reversed)) throw "collision metadata is inconsistent";
		var before = new WasmTypeIdPlan([a]), after = new WasmTypeIdPlan([a, b]);
		if (before.id(a) == after.id(a) || after.compatibleWith(before)) throw "patch accepted a changed live type ID";
		if (before.compatibleWith(after)) throw "patch accepted a removed live type";
		var program = compiler.Frontend.compile('class CaxscQFXbw { public function new() {} } '
			+ 'class CVqowVrIwv { public function new() {} } '
			+ 'function main():Int { var x=new CaxscQFXbw(); var y=new CVqowVrIwv(); return 42; }');
		var planned = WasmTypeIdPlan.forProgram(program);
		if (planned.id(a) == planned.id(b) || planned.id(Array(Dyn)) == planned.id(Dyn))
			throw "program plan omitted or conflated a runtime type";
		for (target in [compiler.backend.Backend.BackendTarget.Wasm32, compiler.backend.Backend.BackendTarget.WasmGc]) {
			var previous = patchProgram(false), next = patchProgram(true), backend = new WasmBackend(),
				options:compiler.backend.Backend.BackendOptions = {target: target, debugNames: true};
			if (WasmPatch.plan(previous, next) != compiler.abi.PatchPlanner.PatchDecision.Patch)
				throw "type ID patch fixture unexpectedly changes the semantic ABI";
			var base = backend.compilePatchBase(previous, options), rejected = false;
			try backend.compilePatch(base.state, next, ["main"], options) catch (error:Dynamic)
				rejected = Std.string(error) == "Wasm patch rejected by runtime type identity: live type IDs changed";
			if (!rejected) throw 'Wasm $target patch did not preserve the emitted runtime type IDs';
		}
		Sys.println("PASS: Wasm runtime type ID plans resolve collisions deterministically");
	}

	static function patchProgram(addCollision:Bool):IrProgram {
		// These array type IDs collide. Both classes exist in the old module;
		// only the new body mentions the additional array descriptor.
		var builder = new IrBuilder(), program = new IrProgram("main");
		builder.typeValue(Array(Obj("ChobQKjKLS")));
		if (addCollision) builder.typeValue(Array(Obj("CbXKjoemVa")));
		builder.returnValue(builder.constInt(42));
		program.functions = [new IrFunction("main", builder.arguments, I32, builder.blocks, None, [])];
		program.objects = [for (name in ["CbXKjoemVa", "ChobQKjKLS"])
			{name:name, isValue:false, base:null, interfaces:[], fields:[], methods:[]}];
		return program;
	}
}
