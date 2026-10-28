import compiler.Compiler;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.compilation.BackendAssembly;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;
import runtime.LoadedModule;
import runtime.PatchSet;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;

/**
 * Edits that add fields to running classes patch the module: objects made before the patch get the fields, with their
 * declaration initializers, through a base class too and in a singleton a closure holds. Removing a field patches as well,
 * a field added back runs its initializer again, an initializer that throws is reported, other threads never see an
 * object the migration has not reached, and the edits a patch cannot make say why they reload.
 */
class LiveObjectLayoutMain {
	static function main():Void {
		addsFields();
		readdsFields();
		migratesWhileThreadsRun();
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

	/** The program of `readdsFields`: `Box.items` and `Box.bad` are what its edits remove and add. */
	static function boxes(items:Bool, bad:Bool, main:String, later:String):String
		return "class Box {\n"
			+ (items ? "  public var items:Array<Int> = [1];\n" : "")
			+ (bad ? "  public var bad:Int = Box.fail();\n" : "")
			+ "  static function fail():Int throw \"no value for bad\";\n"
			+ "  public function new() {}\n"
			+ "}\n"
			+ "class Boxes {\n"
			+ "  public static var first:Null<Box> = null;\n"
			+ "  public static var second:Null<Box> = null;\n"
			+ "}\n"
			+ "function main():Int {\n  if (Boxes.first == null) Boxes.first = new Box();\n  var box:Box = Boxes.first;\n" + main + "}\n"
			+ "function later():Int {\n" + later + "}\n";

	/**
	 * A field removed and added back keeps its slot, but runs its initializer again on every instance: the ones made while it
	 * was gone, which never ran it, and the older ones, which hold a value from before. An initializer that throws leaves the
	 * patch applied and says so.
	 */
	static function readdsFields():Void {
		var withItems = "  box.items.push(0);\n  return box.items.length;\n",
			reading = "  var box:Null<Box> = Boxes.second;\n  return box == null ? -1 : box.items == null ? -2 : box.items.length;\n";
		var compiler = compiler();
		compiler.update("Main.hx", boxes(true, false, withItems, "  return 0;\n"));
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			main = build.functionIds.get("main"),
			later = build.functionIds.get("Main.later");
		expect("the first push", Runtime.callInt(live, main), 2);
		expect("the second push", Runtime.callInt(live, main), 3);
		var revision = patch(compiler, live, build.revision,
			boxes(false, false, "  return 0;\n", "  if (Boxes.second == null) Boxes.second = new Box();\n  return 0;\n"), "removing a field");
		expect("making a box without the field", Runtime.callInt(live, later), 0);
		revision = patch(compiler, live, revision, boxes(true, false, withItems, reading), "adding the field back");
		expect("the old box after its field came back", Runtime.callInt(live, main), 2);
		expect("the box made while the field was gone", Runtime.callInt(live, later), 1);
		compiler.update("Main.hx", boxes(true, true, withItems, reading));
		var failing = compiler.compile("Main"), status:Null<RuntimeStatus> = null, message = "";
		if (failing.requiresReload || failing.patchBytes == null)
			throw "adding a field whose initializer throws required a reload";
		try
			Runtime.patchSet(live, new PatchSet(revision, failing.revision, failing.patchBytes, failing.changedFunctions))
		catch (error:RuntimeError) {
			status = error.status;
			message = error.message;
		}
		if (status != RuntimeStatus.MigrationFailed)
			throw 'a throwing initializer must report MigrationFailed, not $status';
		if (message.indexOf("Box") < 0 || message.indexOf("no value for bad") < 0 || message.indexOf("2 of 2") < 0)
			throw 'the failure must name the class, the exception and the instances: $message';
		expect("the module after the failed initializer", Runtime.liveRevision(live), failing.revision);
		Runtime.dispose(live);
	}

	/**
	 * A worker thread allocates objects of a class, drops them and calls a method that reads the field a patch adds to it,
	 * while the patch applies and migrates. The worker never sees the field unset on an object made before a patch: the patch
	 * commits and migrates with every other thread stopped, the objects the migration found stay allocated until it reaches
	 * them, and code the stopped worker is inside stays allocated too.
	 */
	static function migratesWhileThreadsRun():Void {
		function source(field:String, check:String):String
			return "import sys.thread.Thread;\n"
				+ "class Item {\n  public var value:Int;\n" + field + "  public function new(value:Int) this.value = value;\n"
				+ "  public function check():Int " + check + "\n}\n"
				+ "class Work {\n  public static var failure = \"\";\n  public static var stop = false;\n  public static var done = false;\n  public static var unset = 0;\n  public static var unsetMade = 0;\n"
				// The Int array literal makes the module import what the added field's initializer needs.
				+ "  public static var rounds = 0;\n  public static var kept:Array<Item> = [];\n  public static var lasting:Array<Item> = [];\n"
				// The worker's loop never returns, so it reaches the patched check through a closure, whose slot the patch redirects.
				+ "  public static var sample:Array<Int> = [7];\n  public static var check:Item->Int = item -> item.check();\n  public static var make:Int->Item = i -> new Item(i);\n}\n"
				// `lasting` lives through every patch, so the worker checks objects made before it while the migration runs;
				// `kept` is replaced every round, so collections free objects the migration found.
				+ "function start():Int {\n  Work.lasting = [for (i in 0...3000) new Item(i)];\n"
				// A worker that throws records why and stops, so the test reports it instead of waiting for rounds that never come.
				+ "  Thread.create(function() {\n    try {\n    while (!Work.stop) {\n"
				+ "      var checkOf:Item->Int = Work.check;\n      var makeOf:Int->Item = Work.make;\n      var fresh = [for (i in 0...2000) makeOf(i)];\n"
				+ "      for (item in Work.kept) Work.unsetMade += checkOf(item);\n"
				+ "      for (item in Work.lasting) Work.unset += checkOf(item);\n"
				+ "      Work.kept = fresh;\n      Work.rounds++;\n    }\n    } catch (error:Dynamic) {\n      Work.failure = Std.string(error);\n    }\n"
				+ "    Work.done = true;\n  });\n"
				+ "  while (Work.rounds < 10) Sys.sleep(0.001);\n  return 0;\n}\n"
				+ "function rounds():Int return Work.done ? -1 : Work.rounds;\n"
				+ "function failure():String return Work.failure;\n"
				+ "function unsetMade():Int return Work.unsetMade;\n"
				+ "function finish():Int {\n  Work.stop = true;\n  while (!Work.done) Sys.sleep(0.001);\n  return Work.unset;\n}\n"
				+ "function main():Int return 0;\n";
		var without = source("", "return 0;"),
			// A slow initializer on many objects keeps the migration long enough for an unsynchronized worker to see it.
			with = source("  var tags:Array<Int> = Item.tagsFor();\n  static function tagsFor():Array<Int> {\n"
				+ "    var tags = [];\n    for (i in 0...300) tags.push(i);\n    return tags;\n  }\n",
				"return tags == null || tags.length != 300 ? 1 : 0;");
		var compiler = compiler();
		compiler.update("Main.hx", without);
		var build = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(build.module), build.runtimeIdentity),
			rounds = build.functionIds.get("Main.rounds");
		expect("starting the worker", Runtime.callInt(live, build.functionIds.get("Main.start")), 0);
		var revision = build.revision;
		for (cycle in 0...5) {
			var before = Runtime.callInt(live, rounds);
			revision = patch(compiler, live, revision, with, 'adding a field while a thread runs (cycle $cycle)');
			// Let the worker check objects the migration reached and ones the new constructor made.
			waitForRounds(live, build.functionIds, before + 20);
			revision = patch(compiler, live, revision, without, 'removing the field while a thread runs (cycle $cycle)');
		}
		var unsetMade = Runtime.callInt(live, build.functionIds.get("Main.unsetMade"));
		expect("checks of objects made before a patch that found the added field unset", Runtime.callInt(live, build.functionIds.get("Main.finish")),
			0);
		// A thread stopped inside old code finishes it after the commit: a construction it was in the middle of makes an object
		// without the added field, one per patch at most for this worker (see LIVE_PATCHING.md, "Threads").
		if (unsetMade > 5)
			throw '$unsetMade objects made while the patches applied lack the added field; at most one per patch may';
		Runtime.dispose(live);
	}

	/** Waits until the worker of `migratesWhileThreadsRun` has done `count` rounds, failing if it stops or takes over 10 s. */
	static function waitForRounds(live:LoadedModule, ids:Map<String, Int>, count:Int):Void {
		var startedAt = Sys.time();
		while (true) {
			var done = Runtime.callInt(live, ids.get("Main.rounds"));
			if (done < 0)
				throw 'the worker stopped: ' + Runtime.callString(live, ids.get("Main.failure"));
			if (done >= count)
				return;
			if (Sys.time() - startedAt > 10)
				throw 'the worker did $done rounds in 10 s, not $count';
			Sys.sleep(0.001);
		}
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
