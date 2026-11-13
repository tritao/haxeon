import compiler.Compiler;
import compiler.Diagnostic.CompileError;

/** A structural capability requires every anonymous field to have it. */
class AnonymousConformanceMain {
	static function main():Void {
		rejected('class Ref { public function new() {} } function main():Int { var a = {x:new Ref()}; var b = {x:new Ref()}; return haxeon.Equality.equals(a,b) ? 1 : 0; }',
			"Equatable");
		rejected('class Ref { public function new() {} } function main():Int return haxeon.Hashing.hash({x:new Ref()});', "Hashable");
		rejected('function main():Int { var f = function(x:Int):Int return x; var a = {callback:f}; return haxeon.Equality.equals(a,a) ? 1 : 0; }',
			"Equatable");
		rejected('function main():Int return haxeon.Hashing.hash({values:[1,2]});', "Hashable");
		rejected('class Ref { public function new() {} } function main():Int { var a = [{x:new Ref()}]; return switch a { case [{x:new Ref()}]: 42; default: 0; }; }',
			"Equatable");
		rejectedRecursiveHash('return haxeon.Hashing.hash(c);');
		rejectedRecursiveHash('var map:Map<Chain, Int> = []; map.set(c, 1); return 0;');
		rejectedMutualRecursiveHash();
		rejectedNestedRecursiveHash();
		rejectedStructRecursiveHash();
		rejectedCustomStructRecursiveHash();
		rejectedEnumRecursiveHash();
		rejectedRecursiveEquality();
		rejectedGenericRecursiveHash();
		rejectedNominalGenericRecursiveHash();
		rejectedNestedGenericRecursiveHash();
		rejectedChangedGenericRecursiveHash();
		acceptFiniteNestedGeneric();
		rejectedNonrecursiveAnonymousHash();
		Sys.println("PASS: anonymous equality and hashing reject nonconforming fields");
	}

	static function rejectedNonrecursiveAnonymousHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'enum Link implements Hashable { End; Next(node:Link); } typedef Record = {link:Link, values:Array<Int>}; function main():Int { var value:Record = {link:End, values:[]}; return haxeon.Hashing.hash(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null || diagnostic.diagnostic.code != "E1025" || diagnostic.diagnostic.message.indexOf("recursive field") >= 0)
			throw 'Expected nonrecursive Hashable error, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedRecursiveHash(operation:String):Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'typedef Chain = {value:Int, next:Null<Chain>}; function main():Int { var c:Chain = {value:1, next:null}; ' + operation + ' }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "next"') < 0)
			throw 'Expected recursive field next in E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedRecursiveEquality():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'typedef Chain = {value:Int, next:Null<Chain>}; function main():Int { var c:Chain = {value:1, next:null}; return haxeon.Equality.equals(c,c) ? 1 : 0; }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "next"') < 0
			|| diagnostic.diagnostic.message.indexOf("explicit equals") < 0)
			throw 'Expected recursive Equatable error, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedMutualRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'typedef Left = {right:Null<Right>}; typedef Right = {left:Null<Left>}; function main():Int { var v:Left = {right:null}; return haxeon.Hashing.hash(v); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "left"') < 0)
			throw 'Expected recursive field left in E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedNestedRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'typedef Chain = {next:Null<Chain>}; typedef Wrapper = {chain:Chain}; function main():Int { var v:Wrapper = {chain:{next:null}}; return haxeon.Hashing.hash(v); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "next"') < 0)
			throw 'Expected recursive field next in E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedStructRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'struct Link implements Hashable { public final node:Null<Node>; public function new(node:Null<Node>) this.node = node; } typedef Node = {link:Null<Link>}; function main():Int { var value:Node = {link:null}; return haxeon.Hashing.hash(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null || diagnostic.diagnostic.code != "E1025" || diagnostic.diagnostic.message.indexOf('field "node"') < 0)
			throw 'Expected recursive field node in E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedGenericRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'typedef Chain = {next:Null<Chain>}; function hashable<T:Hashable>(value:T):Int return 0; function main():Int { var value:Chain = {next:null}; return hashable(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "next"') < 0)
			throw 'Expected Hashable generic constraint error, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedNominalGenericRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'struct Link implements Hashable { public final node:Null<Node>; public function new(node:Null<Node>) this.node = node; } typedef Node = {link:Null<Link>}; function hashable<T:Hashable>(value:T):Int return 0; function main():Int return hashable(new Link(null));');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null || diagnostic.diagnostic.code != "E1025")
			throw 'Expected recursive nominal conformance error, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedNestedGenericRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'enum Box<T> implements Hashable { Boxed(value:T); public function equals(other:Box<T>):Bool return true; public function hash():Int return 0; } typedef Chain = {next:Null<Chain>}; typedef Outer = {box:Box<Box<Chain>>}; function main():Int { var value:Outer = {box:Boxed(Boxed({next:null}))}; return haxeon.Hashing.hash(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "next"') < 0)
			throw 'Expected recursive field next through nested generic enum, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedChangedGenericRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'enum Box<T> implements Hashable { End; Item(value:T); Next(value:Box<Chain>); public function equals(other:Box<T>):Bool return true; public function hash():Int return 0; } typedef Chain = {next:Null<Chain>}; typedef Outer = {box:Box<Int>}; function main():Int { var value:Outer = {box:End}; return haxeon.Hashing.hash(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "next"') < 0)
			throw 'Expected recursive field next after changing generic argument, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function acceptFiniteNestedGeneric():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'enum Box<T> implements Hashable { Boxed(value:T); public function equals(other:Box<T>):Bool return true; public function hash():Int return 0; } typedef Inner = {box:Box<Int>}; typedef Outer = {box:Box<Inner>}; function main():Int { var value:Outer = {box:Boxed({box:Boxed(1)})}; return haxeon.Hashing.hash(value); }');
		compiler.compile("Main");
	}

	static function rejectedCustomStructRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'struct Link implements Hashable { public final node:Null<Node>; public function new(node:Null<Node>) this.node = node; public function equals(other:Link):Bool return true; public function hash():Int return 0; } typedef Node = {link:Null<Link>}; function main():Int { var value:Node = {link:null}; return haxeon.Hashing.hash(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('recursive field "node"') < 0)
			throw 'Expected recursive field node in E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejectedEnumRecursiveHash():Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx",
			'enum Link implements Hashable { End; Next(node:Null<Node>); } typedef Node = {link:Link}; function main():Int { var value:Node = {link:End}; return haxeon.Hashing.hash(value); }');
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null || diagnostic.diagnostic.code != "E1025" || diagnostic.diagnostic.message.indexOf("node") < 0)
			throw 'Expected recursive field node in E1025, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}

	static function rejected(source:String, capability:String):Void {
		var compiler = new Compiler();
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", source);
		var diagnostic:Null<CompileError> = null;
		try
			compiler.compile("Main")
		catch (error:CompileError)
			diagnostic = error;
		if (diagnostic == null
			|| diagnostic.diagnostic.code != "E1025"
			|| diagnostic.diagnostic.message.indexOf('does not conform to $capability') < 0)
			throw 'Expected E1025 does not conform to $capability, got ${diagnostic == null ? "success" : diagnostic.diagnostic.message}';
	}
}
