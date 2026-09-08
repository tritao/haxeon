import compiler.Frontend;
import compiler.Diagnostic.CompileError;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;

class AuditVerifierMain {
	static function rejected(program:IrProgram, expected:String):Void {
		try {
			IrVerifier.verify(program);
		} catch (error:String) {
			if (error.indexOf(expected) >= 0)
				return;
			throw error;
		}
		throw 'Verifier accepted malformed IR: $expected';
	}

	static function typeError(source:String):Void {
		try {
			Frontend.compile(source);
		} catch (error:CompileError) {
			if (error.diagnostic.code == "E1002" || error.diagnostic.code == "E1009")
				return;
			throw error;
		}
		throw "Expected a typed conversion diagnostic";
	}

	static function main():Void {
		var builder = new IrBuilder(),
			condition = builder.argument("condition", Bool),
			yes = builder.createBlock(),
			no = builder.createBlock();
		builder.branch(condition, yes, no);
		builder.select(no);
		var value = builder.constInt(42);
		builder.returnValue(value);
		builder.select(yes);
		builder.returnValue(value);
		var program = new IrProgram("main");
		program.functions.push(new IrFunction("main", builder.arguments, I32, builder.blocks));
		rejected(program, "does not dominate");

		var forged = new IrBuilder(), integer = forged.constInt(42);
		forged.returnValue(new IrValue(integer.id, "forged", Bool));
		var forgedProgram = new IrProgram("main");
		forgedProgram.functions.push(new IrFunction("main", [], Bool, forged.blocks));
		rejected(forgedProgram, "definition type");

		var phiBuilder = new IrBuilder(),
			flag = phiBuilder.argument("flag", Bool),
			left = phiBuilder.createBlock(),
			right = phiBuilder.createBlock(),
			join = phiBuilder.createBlock();
		phiBuilder.branch(flag, left, right);
		phiBuilder.select(left);
		var leftValue = phiBuilder.constInt(42);
		phiBuilder.jump(join);
		phiBuilder.select(right);
		phiBuilder.jump(join);
		phiBuilder.select(join);
		var merged = phiBuilder.phi(I32, [{block: left.id, value: leftValue}, {block: right.id, value: leftValue}]);
		phiBuilder.returnValue(merged);
		var phiProgram = new IrProgram("main");
		phiProgram.functions.push(new IrFunction("main", phiBuilder.arguments, I32, phiBuilder.blocks));
		rejected(phiProgram, "does not dominate");

		var critical = new IrBuilder(),
			criticalFlag = critical.argument("flag", Bool),
			initial = critical.constInt(1),
			other = critical.createBlock(),
			criticalJoin = critical.createBlock();
		critical.branch(criticalFlag, criticalJoin, other);
		critical.select(other);
		var alternative = critical.constInt(42);
		critical.jump(criticalJoin);
		critical.select(criticalJoin);
		critical.returnValue(critical.phi(I32, [{block: 0, value: initial}, {block: other.id, value: alternative}]));
		var criticalProgram = new IrProgram("main"),
			criticalFunction = new IrFunction("main", critical.arguments, I32, critical.blocks);
		criticalProgram.functions.push(criticalFunction);
		var before = compiler.ir.codec.IrFunctionStateCodec.encode(criticalFunction);
		compiler.ir.hl.HlLower.lower(criticalProgram);
		if (before.compare(compiler.ir.codec.IrFunctionStateCodec.encode(criticalFunction)) != 0)
			throw "Phi edge splitting mutated cached SSA";
		IrVerifier.verify(criticalProgram);

		typeError('function f(value:Dynamic):Int return 42; function main():Int { var g:(Int)->Int = f; return g("wrong"); }');
		typeError('function main():Int { var a:Array<Int> = [42]; var b:Array<Dynamic> = a; return 42; }');
		typeError('function main():Int { var a:Array<Int> = [42]; var b:Array<Null<Int>> = a; return 42; }');
		Sys.println("PASS: SSA dominance, edge uses, canonical types, and typed conversion diagnostics");
	}
}
