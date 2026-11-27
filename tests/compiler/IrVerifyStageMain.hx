import compiler.core.InternalError;
import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrStageMemos;
import compiler.ir.verify.IrVerifyStage;
import compiler.query.ComputedQueryKind;
import compiler.query.QueryDatabase;

/**
 * Verification that reuses an earlier build's check of a function is as strict as checking it again (`IrVerifyStage`). `f` calls
 * `g(1)`; the same `f` object is checked when `g` takes an integer, must be checked again, and rejected, when `g` takes a Bool, is
 * checked once more when `g` takes an integer again, is held when only an unrelated function appears, and when `g` is replaced by an
 * equal function, which is checked itself.
 */
class IrVerifyStageMain {
	static final database = new QueryDatabase();

	static final memos = new IrStageMemos(database,
		database.register(new ComputedQueryKind<IrFunction>("ir-generation", IrFunctionStateEquality.same)));

	static function callee(argument:IrType, name:String = "g"):IrFunction {
		var builder = new IrBuilder();
		builder.argument("x", argument);
		builder.returnValue(builder.constVoid());
		return new IrFunction(name, builder.arguments, Void, builder.blocks, Ordinary);
	}

	static function caller():IrFunction {
		var builder = new IrBuilder();
		builder.call("g", [builder.constInt(1)], Void);
		builder.returnValue(builder.constInt(0));
		return new IrFunction("f", builder.arguments, I32, builder.blocks, Ordinary);
	}

	/** One build's verification of `functions`, in the session; the names of the functions it checked, not held. */
	static function verify(functions:Array<IrFunction>):Array<String> {
		var program = new IrProgram("f");
		program.functions = functions.copy();
		database.newRevision();
		memos.bodies = true;
		IrFunctionStages.run("verifier", new IrVerifyStage(program, memos.verifyAnswers, false), program.functions,
			memos);
		var kind = memos.stage("verifier", true).functions;
		return [
			for (fn in functions)
				if (kind.computedIn(kind.slotOf(fn.symbol.functionKey())) == database.revision) fn.name
		];
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;

	static function main():Void {
		var f = caller(), g = callee(I32);
		expect(verify([f, g]).join(",") == "f,g", "the first verification checks every function");
		expect(verify([f, g]).length == 0, "an unchanged program is not checked again");
		var rejected = false;
		try
			verify([f, callee(Bool)])
		catch (error:InternalError)
			rejected = error.message.indexOf("f") >= 0;
		expect(rejected, "a function checked against another signature of its callee was not checked again");
		// A signature that changed and changed back is another value of its fact: what read it is checked once more.
		expect(verify([f, g]).join(",") == "f",
			"a function that read a signature which changed and changed back was not checked again");
		expect(verify([f, g, callee(I32, "h")]).join(",") == "h",
			"an unrelated function made the others be checked again");
		expect(verify([f, callee(I32)]).join(",") == "g",
			"a callee replaced by an equal one made its caller be checked again");
		Sys.println("PASS: function verification is reused only while the function and everything it read are unchanged");
	}
}
