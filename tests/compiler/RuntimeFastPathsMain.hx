import compiler.Compiler;
import compiler.hl.HlFunction.HlInstruction;
import compiler.runtime.CompilerIntrinsics;

/** Growth, byte bounds, byte truncation and GC barriers remain correct with inline runtime operations. */
class RuntimeFastPathsMain {
	static final programs = [
		'class Box {public var value:Int;public function new(n:Int)value=n;} function main():Int {hl.Gc.enable(false);var a:Array<Box>=[];a.resize(4096);a.resize(0);var roots:Array<Box>=[];for(i in 0...20000)roots.push(new Box(i));var done=hl.Gc.step(0.001);for(i in 0...2048){a.push(new Box(i));done=hl.Gc.step(1.0);}hl.Gc.major();hl.Gc.enable(true);return a[2047].value==2047 && roots[19999].value==19999?42:1;}',
		'function main():Int { var a:Array<Int>=[];for(i in 0...10000) a.push(i);return a.length==10000 && a[9999]==9999?42:1; }',
		'function main():Int { var a:Array<Float>=[];for(i in 0...1000)a.push(i+0.5);return a.length==1000 && a[999]==999.5?42:1; }',
		'function main():Int { var a:Array<Bool>=[];for(i in 0...1000)a.push(i%2==0);return a[998] && !a[999]?42:1; }',
		'function main():Int { var a:Array<String>=[];for(i in 0...1000)a.push("value"+i);hl.Gc.major();return a[999]=="value999"?42:1; }',
		'class Box {public var value:Int;public function new(n:Int) value=n;} function main():Int {var a:Array<Box>=[];for(i in 0...1000)a.push(new Box(i));hl.Gc.major();return a[999].value==999?42:1;}',
		'function main():Int {var a:Array<Dynamic>=[];for(i in 0...1000)a.push(i);hl.Gc.major();var x:Int=a[999];return x==999?42:1;}',
		'function main():Int {var a:Array<Int64>=[];var n:Int64=42;for(i in 0...1000)a.push(n);return a[999]==n?42:1;}',
		'function main():Int { var a=[1,2,3];a.resize(0);var n=a.push(42);return n==1 && a[0]==42?42:1; }',
		'import haxe.io.Bytes; function main():Int {var b=Bytes.alloc(1000);for(i in 0...1000)b.set(i,i);for(i in 0...1000)if(b.get(i)!=(i&255))return 1;return 42;}',
		'import haxe.io.Bytes; function main():Int {var b=Bytes.alloc(1);b.set(0,-1);return b.get(0)==255?42:1;}',
		'import haxe.io.Bytes; function main():Int {var b=Bytes.alloc(1);try {return b.get(-1);}catch(e:Dynamic){return 42;}}',
		'import haxe.io.Bytes; function main():Int {var b=Bytes.alloc(1);try {b.set(1,42);return 1;}catch(e:Dynamic){return 42;}}',
		'import haxe.io.Bytes; function main():Int {var b=Bytes.alloc(0);try {return b.get(0);}catch(e:Dynamic){return 42;}}',
		'import haxe.io.Bytes; function main():Int {var b:Bytes=null;try {return b.get(0);}catch(e:Dynamic){return 42;}}'
	];

	static function main():Void {
		var warm = create();
		for (index in 0...programs.length)
			for (c in [warm, create()]) {
				c.update("Main.hx", programs[index]);
				var result = c.compile("Main");
				if (GeneratedProgramRunner.exitCode(result) != 42)
					throw 'Runtime fast path case $index failed';
			}
		Sys.println("PASS: runtime fast paths retain growth, GC barriers and byte bounds, cold and incremental");
	}

	static function create():Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addSourceRoot("stdlib");
		return c;
	}
}
