import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import compiler.ir.IrVerifyMemo;

/**
 * Verification that reuses an earlier build's acceptance of a function is as strict as verifying it again. `f` calls `g(1)`; the same `f`
 * object is accepted when `g` takes an integer, must be checked again, and rejected, when `g` takes a Bool, is skipped when only an
 * unrelated function appears, and when `g` is replaced by an equal function.
 */
class IrVerifyMemoMain {
	static function callee(argument:IrType, name:String = "g"):IrFunction {
		var builder = new IrBuilder();
		builder.argument("x", argument);
		builder.returnValue(builder.constVoid());
		return new IrFunction(name, builder.arguments, Void, builder.blocks, None, []);
	}

	static function caller():IrFunction {
		var builder = new IrBuilder();
		builder.call("g", [builder.constInt(1)], Void);
		builder.returnValue(builder.constInt(0));
		return new IrFunction("f", builder.arguments, I32, builder.blocks, None, []);
	}

	static function program(functions:Array<IrFunction>):IrProgram {
		var result = new IrProgram("f");
		result.functions = functions;
		return result;
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;

	static function main():Void {
		var memo = new IrVerifyMemo(), f = caller(), g = callee(I32);
		IrVerifier.verifyReusing(program([f, g]), memo);
		expect(memo.checkedFunctions == 2 && memo.skippedFunctions == 0, "the first verification checks every function");
		IrVerifier.verifyReusing(program([f, g]), memo);
		expect(memo.checkedFunctions == 0 && memo.skippedFunctions == 2, "an unchanged program is not checked again");
		var rejected = false;
		try
			IrVerifier.verifyReusing(program([f, callee(Bool)]), memo)
		catch (error:String)
			rejected = error.indexOf("f") >= 0;
		expect(rejected, "a function accepted against another signature of its callee was not checked again");
		IrVerifier.verifyReusing(program([f, g, callee(I32, "h")]), memo);
		expect(memo.skippedFunctions == 2 && memo.checkedFunctions == 1, "an unrelated function made the others be checked again");
		var replaced = callee(I32);
		IrVerifier.verifyReusing(program([f, replaced]), memo);
		expect(memo.skippedFunctions == 2 && memo.checkedFunctions == 0, "a callee replaced by an equal one was checked again");
		Sys.println("PASS: function verification is reused only while the function and everything it read are unchanged");
	}
}
