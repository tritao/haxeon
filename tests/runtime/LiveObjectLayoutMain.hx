import compiler.Compiler;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.compilation.BackendAssembly;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import runtime.LoadedModule;
import runtime.PatchSet;
import runtime.Runtime;

/**
 * Edits that add fields to running classes patch the module: objects made before the patch get the fields, with their
 * declaration initializers, through a base class too and in a singleton a closure holds. Removing a field patches as well,
 * and the edits a patch cannot make say why they reload.
 */
class LiveObjectLayoutMain {
	static function main():Void {
		addsFields();
		refuses("a field changes type", edited(), edit("ticks:Int = 100", "ticks:Float = 100.0", "ticks++;", "ticks += 1.0;", "return total + ticks;",
			"return total + Std.int(ticks);"), ObjectFieldTypeChanged("App.ticks"));
		refuses("an added method overrides another added one", original(), added("Base", "public function label():Int return 1;")
			.split("class Widget extends Base {\n").join("class Widget extends Base {\n  override public function label():Int return 2;\n"),
			ObjectMethodDispatchChanged("Base.label"));
		refuses("an added method overrides an existing one", original(), added("Widget", "override public function grow():Int return 7;"),
			ObjectMethodDispatchChanged("Widget.grow"));
		refuses("toString is added", original(), added("Model", "public function toString():String return \"model\";"),
			ObjectMethodDispatchChanged("Model.__string"));
		refuses("an override is removed", original(), edited().split("  override public function shrink():Int return 5;\n").join(""),
			ObjectMethodDispatchChanged("Widget.shrink"));
		BackendAssembly.liveFieldReserve = 1;
		refuses("more fields are added than the class reserves", original(), added("Model", "var first:Int = 1;\n  var second:Int = 2;"),
			ObjectFieldReserveExhausted("Model"));
		BackendAssembly.liveFieldReserve = 4;
		Sys.println("PASS: added and removed fields patch running objects, and the edits a patch cannot make reload with their reasons");
	}

	/** The program before the edits; `ticks`, `tag`, `saved` and `bonus` are what the edits add. */
	static function original():String
		return "class Base {\n"
			+ "  public var id:Int;\n"
			+ "  public function new(id:Int) this.id = id;\n"
			+ "  public function describe():Int return id;\n"
			+ "  public function grow():Int return 1;\n"
			+ "  public function shrink():Int return 1;\n"
			+ "}\n"
			+ "class Widget extends Base {\n"
			+ "  public var size:Int = 3;\n"
			+ "  public function new(id:Int) super(id);\n"
			+ "  override public function describe():Int return id * 100 + size;\n"
			+ "  override public function shrink():Int return 5;\n"
			+ "}\n"
			+ "class Model {\n"
			+ "  var count:Int = 0;\n"
			+ "  public function new() {}\n"
			+ "  public function step():Int {\n"
			+ "    count++;\n"
			+ "    return count;\n"
			+ "  }\n"
			+ "}\n"
			+ "class App {\n"
			+ "  public static var current:Null<App> = null;\n"
			+ "  public final model:Model = new Model();\n"
			+ "  public final widgets:Array<Base> = [];\n"
			+ "  public var onTick:Null<Void->Int> = null;\n"
			+ "  public function new() {\n"
			+ "    widgets.push(new Widget(1));\n"
			+ "    widgets.push(new Base(2));\n"
			+ "    onTick = () -> tick();\n"
			+ "  }\n"
			+ "  public function tick():Int {\n"
			+ "    var total = model.step();\n"
			+ "    for (widget in widgets) total += widget.describe();\n"
			+ "    return total;\n"
			+ "  }\n"
			+ "}\n"
			+ "function main():Int {\n"
			+ "  if (App.current == null) App.current = new App();\n"
			+ "  var app:App = App.current;\n"
			+ "  var tick:Void->Int = app.onTick;\n"
			+ "  return tick();\n"
			+ "}\n"
			+ "function fresh():Int {\n"
			+ "  var app = new App();\n"
			+ "  var tick:Void->Int = app.onTick;\n"
			+ "  return tick();\n"
			+ "}\n"
			+ "function reflected():Int {\n"
			+ "  var value:Null<Int> = Reflect.field(App.current, \"ticks\");\n"
			+ "  return value == null ? -1 : value;\n"
			+ "}\n";

	/**
	 * The edit: Model gains `saved` (with an initializer), `bonus` (without one), `order` (a function, initialized from an
	 * added static one) and a method; Base, which Widget extends,
	 * gains `tag`; App, the singleton the stored closure holds, gains `ticks`. The closure itself is unchanged.
	 */
	static function edited():String
		return original().split("  public function describe():Int return id;\n")
			.join("  public var tag:String = \"base\";\n  public function describe():Int return id + tag.length;\n")
			.split("  override public function describe():Int return id * 100 + size;\n")
			.join("  override public function describe():Int return id * 100 + size + tag.length;\n")
			.split("  var count:Int = 0;\n")
			.join("  var count:Int = 0;\n  var saved:Array<String> = [\"a\", \"b\"];\n  var bonus:Int;\n  var order:Int->Int = twice;\n"
				+ "  static function twice(value:Int):Int return value * 2;\n"
				+ "  public function savedCount():Int return order(saved.length) + bonus;\n")
			.split("    count++;\n    return count;\n")
			.join("    count++;\n    bonus += 10;\n    return count + savedCount();\n")
			.split("  public var onTick:Null<Void->Int> = null;\n")
			.join("  public var onTick:Null<Void->Int> = null;\n  var ticks:Int = 100;\n")
			.split("    var total = model.step();\n")
			.join("    ticks++;\n    var total = model.step();\n")
			.split("    return total;\n  }\n}\n")
			.join("    return total + ticks;\n  }\n}\n");

	/** The edited program with a `Counter` class, holding `members`, that App keeps one of and counts each tick with. */
	static function counted(members:String):String
		return edited().split("class App {\n")
			.join("class Counter {\n  var n:Int = 0;\n" + members + "  public function new() {}\n"
				+ "  public function next():Int {\n    n += " + (members == "" ? "1" : "step") + ";\n    return n;\n  }\n}\nclass App {\n")
			.split("  var ticks:Int = 100;\n")
			.join("  var ticks:Int = 100;\n  var counter:Counter = new Counter();\n")
			.split("    return total + ticks;\n")
			.join("    return total + ticks + counter.next();\n");

	static function edit(from1:String, to1:String, from2:String, to2:String, from3:String, to3:String):String
		return edited().split(from1).join(to1).split(from2).join(to2).split(from3).join(to3);

	/** The edited program with `member` added to class `owner`. */
	static function added(owner:String, member:String):String {
		var header = owner == "Widget" ? "class Widget extends Base {\n" : 'class $owner {\n';
		return edited().split(header).join(header + "  " + member + "\n");
	}

	static function compiler():Compiler {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		return compiler;
	}

	static function addsFields():Void {
		var compiler = compiler();
		compiler.update("Main.hx", original());
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			main = build.functionIds.get("main"),
			fresh = build.functionIds.get("Main.fresh"),
			reflected = build.functionIds.get("Main.reflected");
		expect("the first tick", Runtime.callInt(live, main), 106);
		expect("the second tick", Runtime.callInt(live, main), 107);
		expect("the field before it exists", Runtime.callInt(live, reflected), -1);

		var revision = patch(compiler, live, build.revision, edited(), "adding fields");
		// Model: count 3, saved initialized to two names and doubled by order, bonus 0 + 10: 3 + 4 + 10. Widget 1: 100 + 3 + 4.
		// Base 2: 2 + 4. App: ticks initialized to 100, then 101.
		expect("the tick after fields were added", Runtime.callInt(live, main), 17 + 107 + 6 + 101);
		expect("the next tick", Runtime.callInt(live, main), 28 + 113 + 102);
		expect("the added field read by reflection", Runtime.callInt(live, reflected), 102);
		// A new App runs the patched constructors: 1 + 4 + 10, the same widgets, ticks 101.
		expect("a tick of an object made after the patch", Runtime.callInt(live, fresh), 15 + 113 + 101);

		var removed = edited().split("  var bonus:Int;\n").join("")
			.split("order(saved.length) + bonus;").join("order(saved.length);")
			.split("    bonus += 10;\n").join("");
		revision = patch(compiler, live, revision, removed, "removing a field");
		expect("the tick after a field was removed", Runtime.callInt(live, main), 5 + 4 + 113 + 103);

		// The field comes back in the slot it had, with the value it had there.
		revision = patch(compiler, live, revision, edited(), "adding the field back");
		expect("the tick after the field came back", Runtime.callInt(live, main), 6 + 4 + 30 + 113 + 104);

		// A patch adds a class and a field of it, whose initializer makes one for the running App.
		revision = patch(compiler, live, revision, counted(""), "adding a class and a field holding one");
		expect("the tick with the added class", Runtime.callInt(live, main), 7 + 4 + 40 + 113 + 105 + 1);
		// The class the last patch appended has reserved slots too.
		revision = patch(compiler, live, revision, counted("  var step:Int = 5;\n"), "adding a field to an appended class");
		expect("the tick after the appended class gained a field", Runtime.callInt(live, main), 8 + 4 + 50 + 113 + 106 + 6);
		Runtime.dispose(live);
	}

	static function patch(compiler:Compiler, live:LoadedModule, revision:Int, source:String, label:String):Int {
		compiler.update("Main.hx", source);
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw '$label required a reload (requiresReload ${changed.requiresReload}, patch ${changed.patchBytes != null}): '
				+ [for (reason in changed.reloadReasons) Std.string(reason)].join(", ") + ' revision ${changed.revision} base ${changed.baseRevision} changed ${changed.changedFunctions.length} regenerated ${changed.regenerated.length}';
		Runtime.patchSet(live, new PatchSet(revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		return changed.revision;
	}

	/** Compiles `base`, then `source`, which must reload for `expected` among its reasons. */
	static function refuses(label:String, base:String, source:String, expected:AbiChange):Void {
		var compiler = compiler();
		compiler.update("Main.hx", base);
		compiler.compile("Main");
		compiler.update("Main.hx", source);
		var changed = compiler.compile("Main"),
			reasons = [for (reason in changed.reloadReasons) Std.string(reason)];
		if (!changed.requiresReload || changed.patchBytes != null)
			throw 'When $label the build should reload, but it patches';
		if (reasons.indexOf(Std.string(expected)) < 0)
			throw 'When $label the reasons should include $expected: ${reasons.join(", ")}';
	}

	static function expect(label:String, actual:Int, expected:Int):Void
		if (actual != expected)
			throw '$label returned $actual instead of $expected';
}
