import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlWriter;
import compiler.hl.patch.HlPatchReader;
import compiler.Compiler;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * An edit that adds classes and closure environments patches the running module: the patch appends their types to the module's
 * type table. The new classes here are a plain one, a subclass of a loaded class, an implementation of a loaded interface and
 * one of a new interface.
 * A lambda whose captures change becomes a new function with a new environment, and a closure made before the edit keeps the
 * code and environment it was made with.
 */
class AddedClassPatchMain {
	static function main():Void {
		var program = (classes:String, score:String, lambda:String, extra:String) -> "interface Scorer { function score():Int; }\n"
			+ "class Panel implements Scorer {\n"
			+ "  public var keys:Array<String>;\n"
			+ "  public function new() keys = [\"a\", \"b\", \"c\"];\n"
			+ "  public function score():Int return " + score + ";\n"
			+ "}\n"
			+ classes
			+ "class Holder { public static var stored:Null<Int->Int> = null; }\n"
			+ "function total(scorer:Scorer):Int return scorer.score();\n"
			+ "function main():Int {\n"
			+ "  var panel = new Panel();\n"
			+ "  var offset = 5;\n"
			+ "  var scale = 2;\n"
			+ "  var f = " + lambda + ";\n"
			+ "  if (Holder.stored == null) Holder.stored = f;\n"
			+ "  var stored = Holder.stored;\n"
			+ "  return total(panel) * 1000 + (stored == null ? 0 : stored(10)) * 10 + f(1)" + extra + ";\n"
			+ "}\n";
		var compiler = new Compiler();
		compiler.update("Main.hx", program("", "keys.length", "(x:Int) -> x + offset", ""));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			mainId = build.functionIds.get("main");
		// 3 * 1000 + 15 * 10 + 6
		var before = Runtime.callInt(live, mainId);
		if (before != 3156)
			throw 'The program returned $before instead of 3156 before the edit';
		compiler.update("Main.hx", program("class Counter {\n"
			+ "  public var count:Int;\n"
			+ "  public function new(start:Int) count = start;\n"
			+ "  public function bump():Int { count += 10; return count; }\n"
			+ "}\n"
			+ "class Wide extends Panel {\n"
			+ "  public function new() { super(); keys.push(\"d\"); }\n"
			+ "  override public function score():Int return super.score() + 100;\n"
			+ "}\n"
			+ "class Fixed implements Scorer {\n"
			+ "  final value:Int;\n"
			+ "  public function new(value:Int) this.value = value;\n"
			+ "  public function score():Int return value;\n"
			+ "}\n"
			+ "interface Weighted { function weight():Int; }\n"
			+ "class Heavy implements Weighted { public function new() {} public function weight():Int return 9; }\n"
			+ "function weigh(weighted:Weighted):Int return weighted.weight();\n",
			"new Counter(keys.length).bump()", "(x:Int) -> x * scale + offset",
			" + total(new Wide()) * 100000 + total(new Fixed(7)) * 10000000 + weigh(new Heavy())"));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw 'Adding classes required a reload (requiresReload ${changed.requiresReload}, patch ${changed.patchBytes != null}): '
				+ [for (reason in changed.reloadReasons) Std.string(reason)].join(", ");
		var objects = 0, virtuals = 0;
		for (type in HlPatchReader.decode(changed.patchBytes).types)
			switch type {
				case Object(_, _, _, _, _, _): objects++;
				case Virtual(_): virtuals++;
				default:
			}
		// Counter, Wide, Fixed, Heavy and the new lambda's environment; Weighted.
		if (objects < 5 || virtuals < 1)
			throw 'The patch appends $objects object and $virtuals virtual types instead of at least 5 and 1';
		Runtime.patchSet(live, new PatchSet(build.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		// Panel: Counter(3).bump() = 13. The stored closure is the one made before the edit: 10 + 5. The new f: 1 * 2 + 5.
		// Wide: Counter(4).bump() + 100 = 114. Fixed: 7. Heavy, through the new interface Weighted: 9.
		var expected = 13 * 1000 + 15 * 10 + 7 + 114 * 100000 + 7 * 10000000 + 9;
		var after = Runtime.callInt(live, mainId);
		if (after != expected)
			throw 'The patched module returned $after instead of $expected';
		// A later edit of a new class patches too: its type is the module's own now.
		compiler.update("Main.hx", program("class Counter {\n"
			+ "  public var count:Int;\n"
			+ "  public function new(start:Int) count = start;\n"
			+ "  public function bump():Int { count += 20; return count; }\n"
			+ "}\n"
			+ "class Wide extends Panel {\n"
			+ "  public function new() { super(); keys.push(\"d\"); }\n"
			+ "  override public function score():Int return super.score() + 100;\n"
			+ "}\n"
			+ "class Fixed implements Scorer {\n"
			+ "  final value:Int;\n"
			+ "  public function new(value:Int) this.value = value;\n"
			+ "  public function score():Int return value;\n"
			+ "}\n"
			+ "interface Weighted { function weight():Int; }\n"
			+ "class Heavy implements Weighted { public function new() {} public function weight():Int return 9; }\n"
			+ "function weigh(weighted:Weighted):Int return weighted.weight();\n",
			"new Counter(keys.length).bump()", "(x:Int) -> x * scale + offset",
			" + total(new Wide()) * 100000 + total(new Fixed(7)) * 10000000 + weigh(new Heavy())"));
		var edited = compiler.compile("Main");
		if (edited.requiresReload || edited.patchBytes == null)
			throw 'Editing an added class required a reload: ' + [for (reason in edited.reloadReasons) Std.string(reason)].join(", ");
		Runtime.patchSet(live, new PatchSet(changed.revision, edited.revision, edited.patchBytes, edited.changedFunctions));
		expected = 23 * 1000 + 15 * 10 + 7 + 124 * 100000 + 7 * 10000000 + 9;
		after = Runtime.callInt(live, mainId);
		if (after != expected)
			throw 'After editing an added class the patched module returned $after instead of $expected';
		var fresh = Runtime.load(HlWriter.encode(edited.module), edited.runtimeIdentity);
		var clean = Runtime.callInt(fresh, edited.functionIds.get("main"));
		Runtime.dispose(fresh);
		// A fresh module makes its stored closure from the new lambda: 10 * 2 + 5.
		if (clean != expected + 100)
			throw 'The full module returned $clean instead of ${expected + 100}';
		Runtime.dispose(live);
		Sys.println("PASS: adding classes and closure environments patches the running module");
	}
}
