import compiler.Compiler;
import compiler.Diagnostic.CompileError;

class NullableArrayFlowMain {
	static final prelude = 'struct Point { public var x:Int; public function new(x:Int) this.x=x; } '
		+ 'function main():Int { var values:Array<Null<Point>>=[new Point(1),null]; ';

	static function main():Void {
		for (body in [
			'if(values[0]!=null) { values[0]=null; return values[0].x; }',
			'var alias=values; if(values[0]!=null) { alias[0]=null; return values[0].x; }',
			'if(values[0]!=null) { values.shift(); return values[0].x; }',
			'if(values[0]!=null) { for(i in 0...1) values[0]=null; return values[0].x; }'
		]) {
			var compiler = new Compiler();
			compiler.update("Main.hx", prelude + body + ' return 42; }');
			var rejected = false;
			try compiler.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1005";
			if (!rejected) throw 'Nullable array fact survived mutation: $body';
		}
		var compiler = new Compiler();
		compiler.update("Main.hx", prelude + 'if(values[0]!=null) values[0].x += 1; '
			+ 'var result=values[0]; return result == null ? 0 : result.x + 40; }');
		if (GeneratedProgramRunner.exitCode(compiler.compile("Main")) != 42)
			throw "Narrowed array element did not remain a writable place";
		var effect = new Compiler();
		effect.update("Main.hx", 'interface Equatable {} class Node { public var x:Int; public function new() x=42; } '
			+ 'class Holder { public var value:Null<Node>; public function new() value=new Node(); } '
			+ 'class Global { public static var holder:Holder = new Holder(); } '
			+ 'struct Key implements Equatable { public var x:Int; public function new() x=0; public function equals(other:Key):Bool { Global.holder.value=null; return true; } } '
			+ 'function main():Int { var holder=Global.holder; var keys=[new Key()]; '
			+ 'if(holder.value!=null && keys.contains(new Key())) return holder.value.x; return 0; }');
		var rejected = false;
		try effect.compile("Main") catch (error:CompileError) rejected = error.diagnostic.code == "E1005";
		if (!rejected) throw "Struct equality must invalidate mutable facts when it calls user code";
		Sys.println("PASS: nullable array facts track mutations, aliases and loops");
	}
}
