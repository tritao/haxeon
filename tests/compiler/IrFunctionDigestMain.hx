import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.codec.IrFunctionDigest;
import compiler.query.Digest;
import compiler.query.QueryDatabase;
import compiler.query.QueryKind;

/** IR functions as query values: equal content digests equal, any change differs, and the engine treats them so. */
class IrFunctionDigestMain {
	static function expect(value:Bool, message:String):Void
		if (!value)
			throw message;

	static function make(name:String, constant:Int, callee:String, result:IrType):IrFunction {
		var b = new IrBuilder(), receiver = b.argument("receiver", Obj("Box"));
		b.call(callee, [receiver], Void);
		b.returnValue(b.constInt(constant));
		return new IrFunction(name, b.arguments, result, b.blocks, Ordinary);
	}

	static function digestOf(fn:IrFunction):String {
		var digest = new Digest();
		IrFunctionDigest.feed(fn, digest);
		return digest.first + ":" + digest.second;
	}

	static function main():Void {
		var base = make("f", 42, "g", I32), again = make("f", 42, "g", I32);
		expect(base != again && digestOf(base) == digestOf(again), "separately built equal functions digest equal");
		expect(IrFunctionDigest.same(base, again), "and are the same value");
		for (variant in [
			{fn: make("f", 43, "g", I32), what: "a constant"},
			{fn: make("f", 42, "h", I32), what: "a callee"},
			{fn: make("f2", 42, "g", I32), what: "the name"}
		]) {
			expect(digestOf(variant.fn) != digestOf(base), "changing " + variant.what + " changes the digest");
			expect(!IrFunctionDigest.same(variant.fn, base), "changing " + variant.what + " changes the value");
		}

		var database = new QueryDatabase(true);
		var functions = database.register(QueryKind.input("function", IrFunctionDigest.feed, IrFunctionDigest.same));
		var blockCount = database.register(QueryKind.derived("block-count", function(db, key) return db.get(functions,
			key).blocks.length, function(value:Int, digest:Digest) digest.int(value),
			function(left:Int, right:Int) return left == right));
		database.set(functions, 0, base);
		var revision = database.revision;
		expect(database.get(blockCount, 0) == base.blocks.length, "a query over a function");
		database.set(functions, 0, base);
		expect(database.revision == revision, "setting the same function object starts no revision");
		database.set(functions, 0, again);
		expect(database.revision == revision, "setting an equal function starts no revision");
		database.set(functions, 0, make("f", 43, "g", I32));
		expect(database.revision == revision + 1, "a changed function starts one");
		var computations = database.computations;
		expect(database.get(blockCount, 0) == base.blocks.length && database.computations == computations + 1,
			"its reader is recomputed, and checked");

		Sys.println("PASS: IR functions digest by content, agree with their equality, and are query inputs");
	}
}
