import compiler.Compiler;
import compiler.ir.IrInterpreter;
import compiler.Diagnostic.CompileError;

/** Compiler-generated Observable field reads and writes use one shared source per object. */
class ObservableTrackingMain {
	static function main():Void {
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler();
			compiler.update("Observable.hx", "interface Observable {}\n");
			compiler.update("Equatable.hx", "interface Equatable {}\n");
			compiler.update("Tracked.hx", "interface Tracked extends Observable {}\n");
			compiler.update("haxeon/reactive/ReactiveRuntime.hx", runtimeSource());
			compiler.update("haxeon/reactive/ObservableProbe.hx", probeSource());
			compiler.update("haxeon/reactive/ObservableSource.hx", sourceSource());
			compiler.update("Main.hx", programSource());
			compiler.configure(inlineEnabled ? "observable-inline-on" : "observable-inline-off", "test",
				["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
			var result = compiler.compile("Main");
			var value = new IrInterpreter(result.ir).run("main");
			if (value != 42)
				throw 'observable field instrumentation returned $value with inlining ${inlineEnabled ? "enabled" : "disabled"}';
		}
		var structRejected = false;
		try {
			var invalid = new Compiler();
			invalid.update("Observable.hx", "interface Observable {}\n");
			invalid.update("Main.hx", "struct Bad implements Observable {} function main():Int return 0;\n");
			invalid.compile("Main");
		} catch (error:CompileError)
			structRejected = error.diagnostic.message.indexOf("only supported on classes with identity") >= 0;
		if (!structRejected)
			throw "Observable conformance was accepted on a struct";
		Sys.println("PASS: Observable field tracking is generated with and without inlining");
	}

	static function runtimeSource():String
		return 'package haxeon.reactive;\n'
			+ 'class ReactiveRuntime { public static var tracking:Bool = false; public static var wrongThread:Bool = false; '
			+ 'public static function isTracking():Bool return tracking; '
			+ 'public static function createObservableSource(count:Int):ObservableSource return new ObservableSource(count); '
			+ 'public static function recordObservableRead(source:ObservableSource, bit:Int):Void source.recordFieldRead(bit); '
			+ 'public static function invalidateObservable(source:ObservableSource, bit:Int):Void '
			+ 'if (source != null) source.invalidateField(bit); '
			+ 'public static function observableWriteStatus(source:ObservableSource, bit:Int):Int '
			+ 'return source == null || !source.hasFieldReaders(bit) ? 0 : wrongThread ? 2 : tracking ? 1 : 0; }\n';

	static function probeSource():String
		return 'package haxeon.reactive;\n'
			+ 'class ObservableProbe { public static var created:Int = 0; public static var readCount:Int = 0; '
			+ 'public static var readMask:Int = 0; public static var writeCount:Int = 0; public static var writeMask:Int = 0; '
			+ 'public static function read(bit:Int):Void { readCount++; readMask = readMask | (1 << bit); } '
			+ 'public static function write(bit:Int):Void { writeCount++; writeMask = writeMask | (1 << bit); } }\n';

	static function sourceSource():String
		return 'package haxeon.reactive;\n'
			+ 'class ObservableSource { var readers:Array<Bool>; public function new(fieldCount:Int) { readers = []; '
			+ 'while (readers.length < fieldCount) readers.push(false); ObservableProbe.created++; } '
			+ 'public function recordFieldRead(bit:Int):Void { ObservableProbe.read(bit); readers[bit] = true; } '
			+ 'public function hasFieldReaders(bit:Int):Bool return readers[bit]; '
			+ 'public function invalidateField(bit:Int):Void ObservableProbe.write(bit); }\n';

	static function programSource():String
		return 'import haxeon.reactive.ReactiveRuntime; import haxeon.reactive.ObservableProbe; '
			+ 'struct Part implements Equatable { public var value:Int; public function new(value:Int) this.value = value; '
			+ 'public function equals(other:Part):Bool return value % 10 == other.value % 10; } '
			+ 'class BaseModel implements Observable { public var baseValue:Int; public function new(value:Int) baseValue = value; } '
			+ 'class FreshModel implements Observable { public var value:Int; public function new() initialize(); '
			+ 'public function initialize() value = 8; } '
			+ 'class Model extends BaseModel implements Tracked { public var count:Int; public var item:Part; public var ratio:Float; '
			+ '@:unobservable public var cache:Int; '
			+ 'public function new(count:Int, item:Part) { super(7); this.count = count; this.item = item; this.ratio = 0.0; } } '
			+ 'function main():Int { var model = new Model(1, new Part(2)); '
			+ 'ReactiveRuntime.tracking = true; var count = model.count; var item = model.item; var base = model.baseValue; '
			+ 'ReactiveRuntime.tracking = true; var constructedWhileTracking = new Model(9, new Part(9)); '
			+ 'var helperConstructedWhileTracking = new FreshModel(); ReactiveRuntime.tracking = false; '
			+ 'var constructedValue = constructedWhileTracking.count; '
			+ 'var cold = new Model(0, new Part(0)); var ignored = cold.count; '
			+ 'model.count = 1; model.count = 2; model.item = new Part(12); var storedEqualItem = model.item.value == 12; model.item = new Part(3); '
			+ 'model.ratio = -0.0; model.ratio = 0.0 / 0.0; model.ratio = 0.0 / 0.0; '
			+ 'var threw = false, cacheWriteThrew = false; ReactiveRuntime.tracking = true; '
			+ 'try model.count = 3 catch (_:Dynamic) threw = true; try model.cache = 9 catch (_:Dynamic) cacheWriteThrew = true; '
			+ 'ReactiveRuntime.tracking = false; var ownerWriteThrew = false; ReactiveRuntime.wrongThread = true; '
			+ 'try model.count = 4 catch (_:Dynamic) ownerWriteThrew = true; ReactiveRuntime.wrongThread = false; '
			+ 'return count == 1 && item.value == 2 && base == 7 && constructedValue == 9 '
			+ '&& helperConstructedWhileTracking.value == 8 && ignored == 0 && storedEqualItem && threw && ownerWriteThrew && !cacheWriteThrew && model.cache == 9 '
			+ '&& ObservableProbe.created == 1 && ObservableProbe.readCount == 3 && ObservableProbe.readMask == 7 '
			+ '&& ObservableProbe.writeCount == 3 && ObservableProbe.writeMask == 14 ? 42 : 0; }';
}
