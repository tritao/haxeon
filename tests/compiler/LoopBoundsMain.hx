import compiler.Frontend;
import compiler.ir.analysis.IrLoopBounds;
import compiler.ir.cfg.IrBodyGraph;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;

class LoopBoundsMain {
	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function count(source:String, name:String):Int {
		var program = Frontend.compile(source + " function main():Int return 0;"),
			found:Null<IrFunction> = null;
		for (fn in program.functions)
			if (fn.name == name)
				found = fn;
		if (found == null)
			throw "missing function " + name;
		var before = IrFunctionStateCodec.encode(found),
			body = IrBodyBuilder.encode(found, IrTypeIds.ofFunctions([found])),
			proof = new IrLoopBounds(IrLoopBounds.pureNativeCalls(program.natives)).reset(body,
				new IrBodyGraph().reset(body)),
			result = 0;
		for (block in found.blocks)
			for (located in block.instructions)
				switch located.value {
					case ArrayGet(_, array, index):
						if (proof.proven(IrValueId.of(array.id), IrValueId.of(index.id), block.id))
							result++;
					default:
				}
		expect(before.compare(IrFunctionStateCodec.encode(found)) == 0, "analysis mutated " + name);
		return result;
	}

	static function main():Void {
		expect(count("function scan(a:Array<Int>):Int { var n = 0; for (i in 0...a.length) n += a[i]; return n; }",
			"scan") == 1,
			"recognize the pre-increment induction and separate guard block of counted loops");
		expect(count("function scan(a:Array<Int>):Int { var n = 0; for (i in 2...a.length) n += a[i]; return n; }",
			"scan") == 1,
			"nonzero nonnegative loop start");
		expect(count("function scan(a:Array<Int>):Int { var n = 0; for (i in -1...a.length) n += a[i]; return n; }",
			"scan") == 0,
			"negative start cannot use signed upper bound alone");
		expect(count("function scan(a:Array<Int>):Int { var n = 0; for (x in a) n += x; return n; }", "scan") == 1,
			"an array for-in counts from -1 and tests the incremented index against the length");
		expect(count("function resize(a:Array<Int>):Void { a.pop(); } function scan(a:Array<Int>):Int { var n = 0; for (x in a) { resize(a); n += x; } return n; }",
			"scan") == 0,
			"an array for-in whose body may resize the array keeps its check");
		expect(count("function scan(a:Array<Int>):Int { var n = 0; for (i in 0...a.length) for (j in (i + 1)...a.length) n += a[i] + a[j]; return n; }",
			"scan") == 2,
			"nested nbody-style start has a dominating nonnegative outer range");
		expect(count("function scan(a:Array<Int>, n:Int):Int { var sum = 0; for (i in 0...n) sum += a[i]; return sum; }",
			"scan") == 0,
			"unrelated numeric bound is not proof of array length");
		expect(count("function scan(a:Array<Int>):Int { var n = a[0]; for (i in 0...a.length) n += a[i]; return n; }",
			"scan") == 1,
			"access before the dominating guard retains its check");
		expect(count("function resize(a:Array<Int>):Void { a[20] = 7; } function scan(a:Array<Int>):Int { var n = 0; for (i in 0...a.length) { resize(a); n += a[i]; } return n; }",
			"scan") == 0,
			"unknown call can resize aliases");
		expect(count("function scan(a:Array<Int>, b:Array<Int>):Int { var n = 0; for (i in 0...a.length) { b[0] = 1; n += a[i]; } return n; }",
			"scan") == 0,
			"array writes through an alias reject the unchanged-length proof");
		expect(count("function scan(a:Array<Int>):Int { var n = 0; try { for (i in 0...a.length) n += a[i]; } catch (e:Dynamic) { n = 1; } return n; }",
			"scan") == 0,
			"handler edges do not inherit loop facts");
		expect(count("function resize(a:Array<Int>):Void { a.pop(); } function scan(a:Array<Int>):Int { var limit=a.length; resize(a); var sum=0; for(i in 0...limit) sum+=a[i]; return sum; }",
			"scan") == 0,
			"captured length invalidated before loop entry must retain checks");
		expect(count("function scan(a:Array<Int>, alias:Array<Int>):Int { var limit=a.length; alias[20]=7; var sum=0; for(i in 0...limit) sum+=a[i]; return sum; }",
			"scan") == 0,
			"preheader alias write invalidates the captured length conservatively");
		expect(count("function resize(a:Array<Int>):Void { a.pop(); } function scan(a:Array<Int>):Int { resize(a); var sum=0; for(i in 0...a.length) sum+=a[i]; return sum; }",
			"scan") == 1,
			"a fresh length read after resizing still proves the loop access");
		var pure = '@:hlNative("haxeon_runtime", "__math_sqrt") extern function root(x:Float):Float; '
			+ 'function scan(a:Array<Float>):Float { var n = 0.0; for (i in 0...a.length) n += root(a[i]); return n; }';
		expect(count(pure, "scan") == 1, "known scalar math native cannot resize an array");
		expect(count(StringTools.replace(pure, '"haxeon_runtime"', '"foreign"'), "scan") == 0,
			"purity requires the actual ABI binding");
		Sys.println("PASS: counted-loop census recognizes emitted IR and rejects invalidating effects");
	}
}
