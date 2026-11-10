import compiler.Frontend;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import sys.io.File;

/** A shared generic owner must not reinterpret scalar map storage as a reference map. */
class GenericScalarMapOwnerMain {
	static final declaration = 'class ReadView<V> {
 final values:Map<String,V>;
 public function new(values:Map<String,V>) this.values=values;
 public function read(key:String):Null<V> return values.get(key);
}
';

	static function rejects(source:String, owner:String):Void {
		var failure:Null<String> = null;
		try Frontend.compile(source) catch (error:Dynamic) failure = Std.string(error);
		expectDiagnostic(failure, owner);
	}

	static function expectDiagnostic(failure:Null<String>, owner:String):Void {
		if (failure == null || failure.indexOf("E1009") < 0 || failure.indexOf(owner) < 0
			|| failure.indexOf("scalar map values in unspecialized generic owners are not supported yet") < 0)
			throw 'Expected scalar-map owner diagnostic for $owner, got: $failure';
	}

	static function main():Void {
		for (type in ["Bool", "Int", "Int64", "Float", "String"])
			rejects(declaration + 'function main():Int { var map:Map<String,$type>=[]; var view=new ReadView<$type>(map); return 0; }', 'ReadView<${type == "Int64" ? "haxe.Int64" : type}>');
		rejects(declaration + 'function main():Int { var map:Map<String,Bool>=[]; var view=new ReadView(map); return 0; }', 'ReadView<Bool>');
		rejects('typedef Values<V> = Map<String,V>;\n' + StringTools.replace(declaration, "Map<String,V>", "Values<V>")
			+ 'function main():Int { var map:Map<String,Bool>=[]; var view=new ReadView<Bool>(map); return 0; }', 'ReadView<Bool>');
		rejects(declaration + 'class Child<T> extends ReadView<T> { public function new(map:Map<String,T>) super(map); }\n'
			+ 'function main():Int { var map:Map<String,Bool>=[]; var view=new Child<Bool>(map); return 0; }', 'ReadView<Bool>');
		rejects(StringTools.replace(declaration, "String", "Int")
			+ 'function main():Int { var map:Map<Int,Bool>=[]; var view=new ReadView<Bool>(map); return 0; }', 'ReadView<Bool>');
		rejects('class NullableView<V> { final values:Null<Map<String,V>>; public function new(values:Null<Map<String,V>>) this.values=values; } '
			+ 'function main():Int { var map:Map<String,Bool>=[]; var view=new NullableView<Bool>(map); return 0; }', 'NullableView<Bool>');
		rejects('typedef Row<V> = {values:Map<String,V>}; typedef Rows<V> = {stable:Row<Bool>, changing:Row<V>}; '
			+ 'class Multi<V> { final rows:Rows<V>; public function new(rows:Rows<V>) this.rows=rows; } '
			+ 'function main():Int { var map:Map<String,Bool>=[]; var row:Row<Bool>={values:map}; var view=new Multi<Bool>({stable:row,changing:row}); return 0; }', 'Multi<Bool>');
		Frontend.compile('class Reference { public function new() {} } ' + declaration
			+ 'function main():Int { var map:Map<String,Reference>=[]; var view=new ReadView<Reference>(map); return 0; }');
		Frontend.compile(declaration + 'function main():Int { var map:Map<String,Null<Bool>>=[]; var view=new ReadView<Null<Bool>>(map); return 0; }');
		Frontend.compile(declaration + 'function main():Int { var map:Map<String,Dynamic>=[]; var view=new ReadView<Dynamic>(map); return 0; }');
		Frontend.compile(StringTools.replace(StringTools.replace(declaration, "Map<String,V>", "Map<String,Bool>"), "Null<V>", "Null<Bool>")
			+ 'function main():Int { var map:Map<String,Bool>=[]; var view=new ReadView<Int>(map); return 0; }');
		Frontend.compile("interface Equatable {} " + StringTools.replace(declaration, "ReadView<V>", "ReadView<V:Equatable>")
			+ 'function main():Int { var map:Map<String,Bool>=[]; var view=new ReadView<Bool>(map); return 0; }');
		var probe = File.getContent("tests/fixtures/generic-scalar-map-owner/Probe.hx");
		for (target in ["hl", "wasm32", "wasm-gc"]) for (inlining in [false, true]) {
			var compiler = new Compiler(null, CompilerIntrinsics.configuration());
			compiler.configure("map-owner-" + target + inlining, "map-owner",
				CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
			var fixed = StringTools.replace(StringTools.replace(probe, "Map<String,V>", "Map<String,Bool>"), "Null<V>", "Null<Bool>");
			compiler.update("Probe.hx", fixed);
			compiler.compile("Probe");
			compiler.update("Probe.hx", probe);
			var failure:Null<String> = null;
			try compiler.compile("Probe") catch (error:Dynamic) failure = Std.string(error);
			expectDiagnostic(failure, "ReadView<Bool>");
			compiler.update("Probe.hx", fixed);
			compiler.compile("Probe");
		}
		Sys.println("PASS: unsupported scalar-map owners fail closed; supported concrete and specialized fields remain valid");
	}
}
