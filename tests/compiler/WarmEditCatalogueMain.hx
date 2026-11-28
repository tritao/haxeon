using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;

/** How a catalogue program is built in its session. */
enum CatalogueMode {
	/** Plain builds, each compared with a fresh compiler's build of the same sources, byte for byte. */
	Plain;

	/** Live builds, which patch one module: `--check-reuse` builds each from a fresh state and compares (`checkLiveAfresh`). */
	Live;
}

/**
 * One kind of edit: a small program, and the files the edit replaces (null removes one); the edit is then undone in the same
 * session. `known` marks a mode whose builds still fail the check, with the reason; such a case FAILS once it passes.
 */
typedef CatalogueEdit = {
	final kind:String;
	final files:Map<String, String>;
	final edit:Map<String, Null<String>>;
	final ?known:Map<CatalogueMode, String>;
}

/**
 * A catalogue of the kinds of edit a warm compile session has to follow, each applied to a small program in one session, and
 * undone. Every build checks its reuse (`--check-reuse`): the frontend run again from a fresh state must
 * give the IR pipeline the same inputs, and the pipeline run again must give the same IR. A plain build must also write a fresh
 * compiler's bytes; a live build is checked against the program a fresh state makes (`checkLiveAfresh`).
 *
 * Suites that script edits mostly add code; most of these remove, rename or retype something that unchanged modules read, which is
 * what a warm build has to notice without retyping those modules. An edit of a new kind that breaks a session belongs here.
 */
class WarmEditCatalogueMain {
	static function catalogue():Array<CatalogueEdit> {
		var lib = "class Lib { public static function kept(x:Int):Int return x + 1; "
			+ "public static function dropped(x:Int):Int return deep(x, 2); "
			+ "static function deep(x:Int, n:Int):Int return n > 0 ? deep(x, n - 1) : x * 3; }";
		var base = "class Base { public function new() {} public function speak():Int return 1; }";
		var child =
			"class Child extends Base { public function new() super(); override public function speak():Int return 2; }";
		var point = "class Point { public var x:Int; public var y:Int = 7; public var z:Int; "
			+ "public function new(x:Int, z:Int) { this.x = x; this.z = z; } }";
		var shapes =
			"class Shapes { public static function total():Int return new Square(2).area() + new Circle(1).area(); } "
			+ "class Square { final side:Int; public function new(side:Int) this.side = side; public function area():Int return side * side; } "
			+ "class Circle { final radius:Int; public function new(radius:Int) this.radius = radius; public function area():Int return 3 * radius * radius; }";
		var tools = "class Tools { public static function seed():Int return 3; } "
			+ "class Counter { public var n:Int = 0; public function new() {} public function bump():Int return ++n; }";
		var fill = "class Fill { public static function listed(x:Int):Array<Int> return [x, x]; }";
		var picker = "class Picker { public function new() {} public function first(xs:Array<Int>):Int return xs[0]; }";
		var holder =
			"class Holder { public var value:Int; public function new(value:Int) this.value = value; public function get():Int return value; }";
		var pair =
			"class Pair<A> { public final a:A; public final b:Int; public function new(a:A, b:Int) { this.a = a; this.b = b; } }";
		var animal = "class Animal { public function new() {} public function legs():Int return 4; }";
		var pet = "class Pet { public function new() {} public function legs():Int return 2; }";
		var dog = "class Dog { public function new() {} public function name():String return \"rex\"; }";
		var kennel = "class Kennel { public static function hold(d:Dog):Int return d.name().length; }";
		var named = "interface Named { function name():String; }";
		var labeled = "interface Labeled { function name():String; }";
		var cat =
			"class Cat implements Named implements Labeled { public function new() {} public function name():String return \"tom\"; }";
		var probe =
			"class Probe { public static function of(x:Dynamic):Int return (Std.isOfType(x, Named) ? 1 : 0) + (Std.isOfType(x, Labeled) ? 2 : 0); }";
		var stack = "@:generic class Stack<T> { final items:Array<T> = []; public function new() {} "
			+ "public function push(item:T):Int { items.push(item); return items.length; } }";
		var stackUser =
			"class StackUser { public static function count():Int { var s = new Stack<Int>(); s.push(1); return s.push(2); } }";
		var stackMain = "class Main { static function main():Int return StackUser.count(); }";
		var slot = "enum Slot<T> { Full(value:T); Empty; "
			+ "public function map<U>(f:T->U):Slot<U> return switch this { case Full(value): Full(f(value)); case Empty: Empty; } "
			+ "public function or(fallback:T):T return switch this { case Full(value): value; case Empty: fallback; } }";
		var slotMain =
			"class Main { static function main():Int { var s:Slot<Int> = Full(20); return s.map(n -> n * 2).or(0); } }";
		var util =
			"class Util { public static function one():Int return 1; } class Extra { public function new() {} public function n():Int return 5; }";
		var level = "enum abstract Level(Int) to Int { var Low = 1; var High = 2; }";
		return [
			{
				kind: "remove a function",
				files: [
					"Lib.hx" => lib,
					"User.hx" => "class User { public static function use():Int return Lib.kept(5); }",
					"Main.hx"
						=> "class Main { static function main():Int return Lib.kept(1) + Lib.dropped(2) + User.use(); }"
				],
				edit: [
					"Lib.hx" => swap(lib, "public static function dropped(x:Int):Int return deep(x, 2); ", ""),
					"Main.hx" => "class Main { static function main():Int return Lib.kept(1) + User.use(); }"
				]
			},
			{
				kind: "remove an override that unchanged callers dispatch to",
				files: [
					"Base.hx" => base,
					"Child.hx" => child,
					"Talk.hx" => "class Talk { public static function of(b:Base):Int return b.speak(); }",
					"Main.hx"
						=> "class Main { static function main():Int { var b:Base = new Child(); return Talk.of(b) + Talk.of(new Base()); } }"
				],
				edit: ["Child.hx" => swap(child, " override public function speak():Int return 2;", "")]
			},
			{
				kind: "remove an initialized field before one an unchanged module reads",
				files: [
					"Point.hx" => point,
					"Reader.hx" => "class Reader { public static function sum(p:Point):Int return p.x + p.z; }",
					"Main.hx" => "class Main { static function main():Int return Reader.sum(new Point(1, 2)); }"
				],
				edit: ["Point.hx" => swap(point, "public var y:Int = 7; ", "")]
			},
			{
				kind: "remove a class from a module an unchanged module imports",
				files: [
					"Shapes.hx" => shapes,
					"Squares.hx"
						=> "import Shapes; class Squares { public static function nine():Int return new Square(3).area(); }",
					"Main.hx" => "class Main { static function main():Int return Shapes.total() + Squares.nine(); }"
				],
				edit: [
					"Shapes.hx" => swap(swap(shapes, " + new Circle(1).area()", ""),
						" class Circle { final radius:Int; public function new(radius:Int) this.radius = radius; public function area():Int return 3 * radius * radius; }",
						"")
				]
			},
			{
				kind: "remove an enum case before one an unchanged switch matches",
				files: [
					"Color.hx" => "enum Color { Red; Green; Blue; }",
					"Paint.hx"
						=> "class Paint { public static function code(c:Color):Int return switch c { case Red: 1; case Blue: 3; case _: 0; } }",
					"Main.hx"
						=> "class Main { static function main():Int return Paint.code(Blue) + Paint.code(Red) + Paint.code(Green); }"
				],
				edit: [
					"Color.hx" => "enum Color { Red; Blue; }",
					"Main.hx" => "class Main { static function main():Int return Paint.code(Blue) + Paint.code(Red); }"
				]
			},
			{
				kind: "remove a static variable with an initializer before one an unchanged module reads",
				files: [
					"Data.hx"
						=> "class Data { public static var dropped = [7, 8]; public static var kept = \"kept\"; }",
					"Reader.hx" => "class Reader { public static function read():Int return Data.kept.length; }",
					"Main.hx" => "class Main { static function main():Int return Reader.read() + Data.dropped.length; }"
				],
				edit: [
					"Data.hx" => "class Data { public static var kept = \"kept\"; }",
					"Main.hx" => "class Main { static function main():Int return Reader.read(); }"
				]
			},
			{
				kind: "reorder the fields of a class an unchanged module reads",
				files: [
					"Point.hx" => point,
					"Reader.hx" => "class Reader { public static function sum(p:Point):Int return p.x + p.y + p.z; }",
					"Main.hx" => "class Main { static function main():Int return Reader.sum(new Point(1, 2)); }"
				],
				edit: ["Point.hx" => swap(point, "public var x:Int; public var y:Int = 7; public var z:Int;",
					"public var z:Int; public var y:Int = 7; public var x:Int;")]
			},
			{
				kind: "reorder the cases of an enum an unchanged switch matches",
				files: [
					"Color.hx" => "enum Color { Red; Green; Blue; }",
					"Paint.hx"
						=> "class Paint { public static function code(c:Color):Int return switch c { case Red: 1; case Blue: 3; case _: 0; } }",
					"Main.hx"
						=> "class Main { static function main():Int return Paint.code(Blue) + Paint.code(Red) + Paint.code(Green) + Type.enumIndex(Color.Blue); }"
				],
				edit: ["Color.hx" => "enum Color { Blue; Red; Green; }"]
			},
			{
				kind: "turn a field into a property with a getter, which an unchanged module reads",
				files: [
					"Stat.hx" => "class Stat { public var count:Int = 3; public function new() {} }",
					"Reader.hx" => "class Reader { public static function read(s:Stat):Int return s.count + 1; }",
					"Main.hx" => "class Main { static function main():Int return Reader.read(new Stat()); }"
				],
				edit: ["Stat.hx"
					=> "class Stat { public var count(get, never):Int; function get_count():Int return 4; public function new() {} }"]
			},
			{
				kind: "turn a class into a struct, which an unchanged module constructs and reads",
				files: [
					"Pos.hx"
						=> "class Pos { public final x:Int; public final y:Int; public function new(x:Int, y:Int) { this.x = x; this.y = y; } }",
					"Reader.hx"
						=> "class Reader { public static function sum():Int { var p = new Pos(1, 2); return p.x + p.y; } }",
					"Main.hx" => "class Main { static function main():Int return Reader.sum(); }"
				],
				edit: ["Pos.hx"
					=> "struct Pos { public final x:Int; public final y:Int; public function new(x:Int, y:Int) { this.x = x; this.y = y; } }"]
			},
			{
				kind: "change an argument's type, which an unchanged module passes a literal to",
				files: [
					"Half.hx" => "class Half { public static function of(x:Int):Int return Std.int(x / 2); }",
					"Caller.hx" => "class Caller { public static function run():Int return Half.of(9); }",
					"Main.hx" => "class Main { static function main():Int return Caller.run(); }"
				],
				edit: ["Half.hx" => "class Half { public static function of(x:Float):Int return Std.int(x / 2); }"]
			},
			{
				kind: "change the types of a static extension an unchanged module calls through a using",
				files: [
					"Ext.hx" => "class Ext { public static function doubled(x:Int):Int return x * 2; }",
					"Caller.hx"
						=> "using Ext; class Caller { public static function run():Int return 3.doubled() > 1 ? 1 : 0; }",
					"Main.hx" => "class Main { static function main():Int return Caller.run(); }"
				],
				edit: ["Ext.hx" => "class Ext { public static function doubled(x:Float):Float return x * 2.5; }"]
			},
			{
				kind: "change a module-level function's inferred return type, which an unchanged module infers from",
				files: [
					"Tools.hx" => "function measure() return 2;",
					"Reader.hx"
						=> "class Reader { public static function read():Int { var v = Tools.measure(); return v > 1 ? 1 : 0; } }",
					"Main.hx" => "class Main { static function main():Int return Reader.read(); }"
				],
				edit: ["Tools.hx" => "function measure() return 2.5;"]
			},
			{
				kind: "rename a function",
				files: [
					"Lib.hx" => lib,
					"User.hx" => "class User { public static function use():Int return Lib.kept(5); }",
					"Main.hx"
						=> "class Main { static function main():Int return Lib.kept(1) + Lib.dropped(2) + User.use(); }"
				],
				edit: [
					"Lib.hx" => swap(lib, "function dropped(", "function renamed("),
					"Main.hx"
						=> "class Main { static function main():Int return Lib.kept(1) + Lib.renamed(2) + User.use(); }"
				]
			},
			{
				kind: "rename a field before one an unchanged module reads",
				files: [
					"Point.hx" => point,
					"Reader.hx" => "class Reader { public static function sum(p:Point):Int return p.x + p.z; }",
					"Main.hx" => "class Main { static function main():Int return Reader.sum(new Point(1, 2)); }"
				],
				edit: ["Point.hx" => swap(point, "public var y:Int", "public var w:Int")]
			},
			{
				kind: "rename a class of a module",
				files: [
					"Tools.hx" => tools,
					"Seeds.hx" => "class Seeds { public static function get():Int return Tools.seed(); }",
					"Main.hx"
						=> "import Tools; class Main { static function main():Int return new Counter().bump() + Seeds.get(); }"
				],
				edit: [
					"Tools.hx" => swap(tools, "class Counter", "class Tally"),
					"Main.hx"
						=> "import Tools; class Main { static function main():Int return new Tally().bump() + Seeds.get(); }"
				]
			},
			{
				kind: "rename an enum case an unchanged switch does not name",
				files: [
					"Mode.hx" => "enum Mode { Fast; Slow; }",
					"Speed.hx"
						=> "class Speed { public static function of(m:Mode):Int return switch m { case Slow: 1; case _: 2; } }",
					"Main.hx" => "class Main { static function main():Int return Speed.of(Fast) + Speed.of(Slow); }"
				],
				edit: [
					"Mode.hx" => "enum Mode { Quick; Slow; }",
					"Main.hx" => "class Main { static function main():Int return Speed.of(Quick) + Speed.of(Slow); }"
				]
			},
			{
				kind: "make a static function generic, which an unchanged module calls",
				files: [
					"Fill.hx" => fill,
					"Caller.hx" => "class Caller { public static function size():Int return Fill.listed(21).length; }",
					"Main.hx" => "class Main { static function main():Int return Caller.size(); }"
				],
				edit: ["Fill.hx" => "class Fill { public static function listed<T>(x:T):Array<T> return [x, x]; }"]
			},
			{
				kind: "make a method generic, which an unchanged module calls",
				files: [
					"Picker.hx" => picker,
					"Caller.hx"
						=> "class Caller { public static function pick():Int return new Picker().first([4, 5]); }",
					"Main.hx" => "class Main { static function main():Int return Caller.pick(); }"
				],
				edit: ["Picker.hx" => swap(picker, "first(xs:Array<Int>):Int", "first<T>(xs:Array<T>):T")]
			},
			{
				kind: "add a type parameter to a class an unchanged module constructs",
				files: [
					"Holder.hx" => holder,
					"Caller.hx" => "class Caller { public static function get():Int return new Holder(3).get() + 1; }",
					"Main.hx" => "class Main { static function main():Int return Caller.get(); }"
				],
				edit: [
					"Holder.hx"
						=> "class Holder<T> { public var value:T; public function new(value:T) this.value = value; public function get():T return value; }"
				]
			},
			{
				kind: "add a second type parameter to a class an unchanged module constructs",
				files: [
					"Pair.hx" => pair,
					"Caller.hx"
						=> "class Caller { public static function sum():Int { var p = new Pair(1, 2); return p.a + p.b; } }",
					"Main.hx" => "class Main { static function main():Int return Caller.sum(); }"
				],
				edit: [
					"Pair.hx"
						=> "class Pair<A, B> { public final a:A; public final b:B; public function new(a:A, b:B) { this.a = a; this.b = b; } }"
				]
			},
			{
				kind: "add a base class",
				files: [
					"Animal.hx" => animal,
					"Dog.hx" => dog,
					"Kennel.hx" => kennel,
					"Main.hx"
						=> "class Main { static function main():Int return Kennel.hold(new Dog()) + new Animal().legs(); }"
				],
				edit: [
					"Dog.hx" => swap(swap(dog, "class Dog", "class Dog extends Animal"), "public function new() {}",
						"public function new() super();"),
					"Main.hx"
						=> "class Main { static function main():Int return Kennel.hold(new Dog()) + new Dog().legs(); }"
				]
			},
			{
				kind: "change a base class an unchanged module calls through",
				files: [
					"Animal.hx" => animal,
					"Pet.hx" => pet,
					"Dog.hx" => swap(swap(dog, "class Dog", "class Dog extends Animal"), "public function new() {}",
						"public function new() super();"),
					"Kennel.hx"
						=> "class Kennel { public static function hold(d:Dog):Int return d.name().length + d.legs(); }",
					"Main.hx"
						=> "class Main { static function main():Int return Kennel.hold(new Dog()) + new Pet().legs(); }"
				],
				edit: [
					"Dog.hx" => swap(swap(dog, "class Dog", "class Dog extends Pet"), "public function new() {}",
						"public function new() super();")
				]
			},
			{
				kind: "add an interface an unchanged module tests for",
				files: [
					"Named.hx" => named,
					"Labeled.hx" => labeled,
					"Dog.hx" => dog,
					"Cat.hx" => cat,
					"Probe.hx" => probe,
					"Main.hx"
						=> "class Main { static function main():Int return Probe.of(new Dog()) + Probe.of(new Cat()); }"
				],
				edit: ["Dog.hx" => swap(dog, "class Dog", "class Dog implements Named")]
			},
			{
				kind: "implement an interface only an unchanged module's type test names",
				files: [
					"Named.hx" => named,
					"Dog.hx" => dog,
					"Probe.hx"
						=> "class Probe { public static function of(x:Dynamic):Int return Std.isOfType(x, Named) ? 1 : 0; }",
					"Main.hx" => "class Main { static function main():Int return Probe.of(new Dog()); }"
				],
				edit: ["Dog.hx" => swap(dog, "class Dog", "class Dog implements Named")]
			},
			{
				kind: "change an interface an unchanged module tests for",
				files: [
					"Named.hx" => named,
					"Labeled.hx" => labeled,
					"Dog.hx" => swap(dog, "class Dog", "class Dog implements Named"),
					"Cat.hx" => cat,
					"Probe.hx" => probe,
					"Main.hx"
						=> "class Main { static function main():Int return Probe.of(new Dog()) + Probe.of(new Cat()); }"
				],
				edit: ["Dog.hx" => swap(dog, "class Dog", "class Dog implements Labeled")]
			},
			{
				kind: "change a field's type, which an unchanged module reads",
				files: [
					"Stat.hx" => "class Stat { public var count:Int = 3; public function new() {} }",
					"Reader.hx"
						=> "class Reader { public static function big(s:Stat):Int return s.count > 1 ? 1 : 0; }",
					"Main.hx" => "class Main { static function main():Int return Reader.big(new Stat()); }"
				],
				edit: ["Stat.hx" => "class Stat { public var count:Float = 3.5; public function new() {} }"]
			},
			{
				kind: "change a struct field's type, which an unchanged module reads",
				files: [
					"Pos.hx"
						=> "struct Pos { public final x:Int; public final y:Int; public function new(x:Int, y:Int) { this.x = x; this.y = y; } }",
					"Reader.hx"
						=> "class Reader { public static function far(p:Pos):Int return p.x + p.y > 2 ? 1 : 0; }",
					"Main.hx" => "class Main { static function main():Int return Reader.far(new Pos(1, 2)); }"
				],
				edit: [
					"Pos.hx"
						=> "struct Pos { public final x:Float; public final y:Int; public function new(x:Float, y:Int) { this.x = x; this.y = y; } }"
				]
			},
			{
				kind: "add a specialization of an @:generic class",
				files: ["Stack.hx" => stack, "StackUser.hx" => stackUser, "Main.hx" => stackMain],
				edit: ["Main.hx"
					=> "class Main { static function main():Int return StackUser.count() + new Stack<String>().push(\"a\"); }"]
			},
			{
				kind: "change the fields of an @:generic class an unchanged module specializes",
				files: ["Stack.hx" => stack, "StackUser.hx" => stackUser, "Main.hx" => stackMain],
				edit: [
					"Stack.hx" => swap(swap(stack, "final items:Array<T> = [];",
						"final items:Array<T> = []; public var pushes:Int = 0;"),
						"items.push(item);", "items.push(item); pushes++;")
				]
			},
			{
				kind: "give an @:generic class an unchanged module specializes a base class",
				files: [
					"Stack.hx" => stack,
					"Counted.hx" => "class Counted { public var count:Int = 0; public function new() {} }",
					"StackUser.hx" => stackUser,
					"Main.hx"
						=> "class Main { static function main():Int return StackUser.count() + new Counted().count; }"
				],
				edit: [
					"Stack.hx" => swap(swap(stack, "class Stack<T>", "class Stack<T> extends Counted"),
						"public function new() {}",
						"public function new() super();")
				]
			},
			{
				kind: "change the base class of an @:generic class an unchanged module specializes",
				files: [
					"Stack.hx" => swap(swap(stack, "class Stack<T>", "class Stack<T> extends Counted"),
						"public function new() {}",
						"public function new() super();"),
					"Counted.hx" => "class Counted { public var count:Int = 0; public function new() {} }",
					"StackUser.hx" => stackUser,
					"Main.hx" => stackMain
				],
				edit: ["Counted.hx"
					=> "class Counted { public var label:String = \"c\"; public var count:Int = 0; public function new() {} }"]
			},
			{
				kind: "edit a body in a program with an @:generic class",
				files: ["Stack.hx" => stack, "StackUser.hx" => stackUser, "Main.hx" => stackMain],
				edit: ["Main.hx" => "class Main { static function main():Int return StackUser.count() + 1; }"]
			},
			{
				kind: "use a generic enum method at a second type",
				files: ["Slot.hx" => slot, "Main.hx" => slotMain],
				edit: [
					"Main.hx"
						=> "class Main { static function main():Int { var s:Slot<Int> = Full(20); return s.map(n -> n * 2).or(0) + s.map(n -> \"n\" + n).or(\"\").length; } }"
				]
			},
			{
				kind: "remove one of two calls to a generic enum method at a type, whose body alone names an enum at it",
				files: [
					"Mark.hx" => "enum Mark<T> { Some(v:T); None; }",
					"Slot.hx"
						=> "enum Slot<T> { Full(value:T); Empty; public function boxed<U>(f:T->U):Int return switch this { case Full(value): var m:Mark<U> = Some(f(value)); switch m { case Some(_): 1; case None: 2; }; case Empty: 0; } }",
					"Zeta.hx"
						=> "class Zeta { public static function text():Int { var s:Slot<Int> = Full(3); return s.boxed(n -> \"z\" + n); } }",
					"Main.hx"
						=> "class Main { static function main():Int { var s:Slot<Int> = Full(20); return s.boxed(n -> \"m\" + n) + Zeta.text(); } }"
				],
				edit: ["Main.hx" => "class Main { static function main():Int return Zeta.text(); }"]
			},
			{
				kind: "change the type a typedef names, which an unchanged module resolves through",
				files: [
					"Count.hx" => "typedef Count = Int;",
					"Counts.hx" => "class Counts { public static function next():Count return 2; }",
					"Reader.hx"
						=> "class Reader { public static function positive():Int { var c = Counts.next(); return c > 0 ? 1 : 0; } }",
					"Main.hx" => "class Main { static function main():Int return Reader.positive(); }"
				],
				edit: ["Count.hx" => "typedef Count = Float;"]
			},
			{
				kind: "change the class a typedef names, which unchanged modules construct and call through",
				files: [
					"Shape.hx" => "typedef Shape = Square;",
					"Square.hx"
						=> "class Square { final n:Int; public function new(n:Int) this.n = n; public function area():Int return n * n; }",
					"Circle.hx"
						=> "class Circle { final n:Int; public function new(n:Int) this.n = n; public function area():Int return 3 * n * n; }",
					"Make.hx" => "class Make { public static function shape(n:Int):Shape return new Shape(n); }",
					"Area.hx" => "class Area { public static function of(s:Shape):Int return s.area(); }",
					"Main.hx"
						=> "class Main { static function main():Int return Area.of(Make.shape(2)) + new Circle(1).area() + new Square(1).area(); }"
				],
				edit: ["Shape.hx" => "typedef Shape = Circle;"]
			},
			{
				kind: "change an abstract's underlying type, which an unchanged module uses",
				files: [
					"Meters.hx"
						=> "abstract Meters(Int) { public function new(v:Int) this = v; public function value():Int return this; }",
					"Track.hx" => "class Track { public static function length(m:Meters):Int return m.value() + 1; }",
					"Main.hx" => "class Main { static function main():Int return Track.length(new Meters(4)); }"
				],
				edit: [
					"Meters.hx"
						=> "abstract Meters(Float) { public function new(v:Int) this = v + 0.5; public function value():Int return Std.int(this); }"
				]
			},
			{
				kind: "change an enum abstract's value, which an unchanged module reads",
				files: [
					"Level.hx" => level,
					"Gauge.hx" => "class Gauge { public static function high():Int return Level.High; }",
					"Main.hx" => "class Main { static function main():Int return Gauge.high() + Level.Low; }"
				],
				edit: ["Level.hx" => swap(level, "var High = 2;", "var High = 5;")]
			},
			{
				kind: "move a class to a module of its own, which an unchanged module imports from the old one",
				files: [
					"Util.hx" => util,
					"User.hx"
						=> "import Util; class User { public static function use():Int return new Extra().n() + Util.one(); }",
					"Main.hx" => "class Main { static function main():Int return User.use(); }"
				],
				edit: [
					"Util.hx" => "class Util { public static function one():Int return 1; }",
					"Extra.hx" => "class Extra { public function new() {} public function n():Int return 5; }"
				]
			},
			{
				kind: "move a class into a module an unchanged module imports, out of the module of its own",
				files: [
					"Util.hx" => "class Util { public static function one():Int return 1; }",
					"Extra.hx" => "class Extra { public function new() {} public function n():Int return 5; }",
					"User.hx"
						=> "import Util; class User { public static function use():Int return new Extra().n() + Util.one(); }",
					"Main.hx" => "class Main { static function main():Int return User.use(); }"
				],
				edit: ["Util.hx" => util, "Extra.hx" => null]
			},
			{
				kind: "remove a module of an unchanged module's package, whose name then resolves to the root package",
				files: [
					"Helper.hx" => "class Helper { public static function id():Int return 1; }",
					"pack/Helper.hx" => "package pack; class Helper { public static function id():Int return 2; }",
					"pack/User.hx"
						=> "package pack; class User { public static function use():Int return Helper.id(); }",
					"Main.hx" => "import pack.User; class Main { static function main():Int return User.use(); }"
				],
				edit: ["pack/Helper.hx" => null]
			},
			{
				kind: "add a module to a package an unchanged module imports with a wildcard, which a name then resolves to",
				files: [
					"Helper.hx" => "class Helper { public static function id():Int return 1; }",
					"pack/Tools.hx" => "package pack; class Tools { public static function two():Int return 2; }",
					"User.hx"
						=> "import pack.*; class User { public static function use():Int return Helper.id() + Tools.two(); }",
					"Main.hx" => "class Main { static function main():Int return User.use(); }"
				],
				edit: ["pack/Helper.hx" => "package pack; class Helper { public static function id():Int return 3; }"]
			},
			{
				kind: "change an inline function an unchanged module calls",
				files: [
					"Scale.hx" => "class Scale { public static inline function of(x:Int):Int return x * 2; }",
					"Caller.hx" => "class Caller { public static function run():Int return Scale.of(4); }",
					"Main.hx" => "class Main { static function main():Int return Caller.run(); }"
				],
				edit: ["Scale.hx" => "class Scale { public static inline function of(x:Int):Int return x * 3 + 1; }"]
			},
			{
				kind: "make a function inline, which an unchanged module calls",
				files: [
					"Scale.hx" => "class Scale { public static function of(x:Int):Int return x * 2; }",
					"Caller.hx" => "class Caller { public static function run():Int return Scale.of(4); }",
					"Main.hx" => "class Main { static function main():Int return Caller.run(); }"
				],
				edit: ["Scale.hx" => "class Scale { public static inline function of(x:Int):Int return x * 2; }"]
			},
			{
				kind: "change a default argument value an unchanged module relies on",
				files: [
					"Pad.hx" => "class Pad { public static function by(x:Int, step:Int = 1):Int return x + step; }",
					"Caller.hx" => "class Caller { public static function run():Int return Pad.by(3); }",
					"Main.hx" => "class Main { static function main():Int return Caller.run(); }"
				],
				edit: ["Pad.hx" => "class Pad { public static function by(x:Int, step:Int = 2):Int return x + step; }"]
			},
			{
				kind: "change a static initializer an unchanged module reads",
				files: [
					"Data.hx" => "class Data { public static var table = [1, 2, 3]; public static final limit = 10; }",
					"Reader.hx"
						=> "class Reader { public static function read():Int return Data.table.length + Data.limit; }",
					"Main.hx" => "class Main { static function main():Int return Reader.read(); }"
				],
				edit: ["Data.hx"
					=> "class Data { public static var table = [1, 2, 3, 4]; public static final limit = 20; }"]
			},
			{
				kind: "change a static initializer's inferred type, which an unchanged module reads",
				files: [
					"Data.hx" => "class Data { public static var scale = 2; }",
					"Reader.hx" => "class Reader { public static function read():Int return Data.scale > 1 ? 1 : 0; }",
					"Main.hx" => "class Main { static function main():Int return Reader.read(); }"
				],
				edit: ["Data.hx" => "class Data { public static var scale = 2.5; }"]
			},
			{
				kind: "edit a body so its inferred return type changes, which unchanged modules infer from",
				files: [
					"Lib.hx" => "class Lib { public static function value() return 1; }",
					"Twice.hx" => "class Twice { public static function of() return Lib.value() * 2; }",
					"Reader.hx"
						=> "class Reader { public static function read():Int { var v = Twice.of(); return v > 0 ? 1 : 0; } }",
					"Main.hx" => "class Main { static function main():Int return Reader.read(); }"
				],
				edit: ["Lib.hx" => "class Lib { public static function value() return 1.5; }"]
			},
			{
				kind: "add an import that changes what a name resolves to",
				files: [
					"Helper.hx" => "class Helper { public static function id():Int return 1; }",
					"pack/Helper.hx" => "package pack; class Helper { public static function id():Int return 2; }",
					"Main.hx" => "class Main { static function main():Int return Helper.id(); }"
				],
				edit: ["Main.hx"
					=> "import pack.Helper; class Main { static function main():Int return Helper.id(); }"]
			},
			{
				kind: "add a using and call through it",
				files: [
					"Ext.hx" => "class Ext { public static function doubled(x:Int):Int return x * 2; }",
					"Main.hx" => "class Main { static function main():Int return Ext.doubled(3); }"
				],
				edit: ["Main.hx" => "using Ext; class Main { static function main():Int return 3.doubled(); }"]
			},
			{
				kind: "change an enum case's payload type, which an unchanged module matches",
				files: [
					"Item.hx" => "enum Item { One(n:Int); None; }",
					"Match.hx"
						=> "class Match { public static function of(i:Item):Int return switch i { case One(n): n > 0 ? 1 : 0; case None: 2; } }",
					"Main.hx" => "class Main { static function main():Int return Match.of(One(3)) + Match.of(None); }"
				],
				edit: ["Item.hx" => "enum Item { One(n:Float); None; }"]
			},
			{
				kind: "add a payload to an enum case",
				files: [
					"Item.hx" => "enum Item { One(n:Int); None; }",
					"Match.hx"
						=> "class Match { public static function of(i:Item):Int return switch i { case One(n): n; case _: 2; } }",
					"Main.hx" => "class Main { static function main():Int return Match.of(One(3)) + Match.of(None); }"
				],
				edit: [
					"Item.hx" => "enum Item { One(n:Int); None(why:String); }",
					"Main.hx"
						=> "class Main { static function main():Int return Match.of(One(3)) + Match.of(None(\"x\")); }"
				]
			},
			{
				kind: "make a Void function return a value, which an unchanged module calls",
				files: [
					"Log.hx"
						=> "class Log { public static var total = 0; public static function add(x:Int) { total += x; } }",
					"Caller.hx"
						=> "class Caller { public static function run():Int { Log.add(3); [4, 5].map(x -> { Log.add(x); x; }); return Log.total; } }",
					"Main.hx" => "class Main { static function main():Int return Caller.run(); }"
				],
				edit: ["Log.hx"
					=> "class Log { public static var total = 0; public static function add(x:Int) { total += x; return total; } }"]
			},
			{
				kind: "remove a body's only structure, while an unchanged function's signature names another",
				files: [
					"Shape.hx" => "class Shape { public static function corner():{x:Int, y:Int} return {x: 1, y: 2}; }",
					"Main.hx"
						=> "class Main { static function main():Int { var size = {w: 3, h: 4}; return Shape.corner().x + size.w; } }"
				],
				edit: ["Main.hx" => "class Main { static function main():Int return Shape.corner().x + 3; }"]
			},
			{
				kind: "remove a static initializer whose value is the program's only structure of its shape",
				files: [
					"Config.hx"
						=> "class Config { public static var limit = 3; public static var origin = {x: 0, y: 0}; }",
					"Main.hx" => "class Main { static function main():Int return Config.limit; }"
				],
				edit: ["Config.hx" => "class Config { public static var limit = 3; }"]
			},
			{
				kind: "remove the only field whose type names a generic enum at a type",
				files: [
					"Slot.hx" => "enum Slot<T> { Full(value:T); Empty; }",
					"Box.hx"
						=> "class Box { public var count:Int = 1; public var label:Slot<String> = Empty; public function new() {} }",
					"Main.hx"
						=> "class Main { static function main():Int { var s:Slot<Int> = Full(2); return new Box().count + switch s { case Full(v): v; case Empty: 0; }; } }"
				],
				edit: ["Box.hx" => "class Box { public var count:Int = 1; public function new() {} }"]
			},
			{
				kind: "remove the only field whose type names an @:generic class at a type",
				files: [
					"Stack.hx" => stack,
					"StackUser.hx" => stackUser,
					"Holder.hx"
						=> "class Holder { public var count:Int = 1; public var names:Stack<String> = new Stack<String>(); public function new() {} }",
					"Main.hx"
						=> "class Main { static function main():Int return StackUser.count() + new Holder().count; }"
				],
				edit: ["Holder.hx" => "class Holder { public var count:Int = 1; public function new() {} }"]
			},
			{
				kind: "stop asking for a specialization whose closure keeps a captured local in a cell",
				files: [
					"Gen.hx"
						=> "class Gen { @:generic public static function counter<T>(x:T):Void->T { var n = 0; return () -> { n++; return x; }; } }",
					"Main.hx"
						=> "class Main { static function main():Int { var a = Gen.counter(3); var b = Gen.counter(\"ab\"); return a() + b().length; } }"
				],
				edit: ["Main.hx" => "class Main { static function main():Int return Gen.counter(3)(); }"]
			},
			{
				kind: "remove the only conversion that needed an iteration adapter, which has an environment of its own",
				files: [
					"Sum.hx"
						=> "class Sum { public static function total(xs:Iterable<Int>):Int { var s = 0; for (x in xs) s += x; return s; } public static function seed():Int return 4; }",
					"Main.hx" => "class Main { static function main():Int return Sum.total([1, 2, 3]) + Sum.seed(); }"
				],
				edit: ["Main.hx" => "class Main { static function main():Int return Sum.seed(); }"]
			}
		];
	}

	static function main():Void {
		var failures:Array<String> = [], started = Sys.time(), builds = 0;
		for (entry in catalogue())
			for (mode in [Plain, Live]) {
				var known = entry.known == null ? null : entry.known.get(mode);
				var failure = try {
					builds += run(entry, mode);
					null;
				} catch (error:Dynamic) Std.string(error);
				var label = '${entry.kind} (${mode == Plain ? "plain" : "live"})';
				if (failure != null && known == null)
					failures.push('$label: $failure');
				else if (failure == null && known != null)
					failures.push('$label passes but is marked as a known failure ($known): remove the marker');
				else if (failure != null)
					Sys.println('known failure: $label: $known');
			}
		if (failures.length > 0)
			throw failures.join("\n");
		Sys.println('PASS: every catalogued edit rebuilds warm as a fresh build ($builds builds, ${Math.round(Sys.time() - started)} s)');
	}

	/** Builds `entry` cold, after its edit and after undoing it, all in one session; returns the number of builds. */
	static function run(entry:CatalogueEdit, mode:CatalogueMode):Int {
		var files = [for (path => text in entry.files) path => text],
			compiler = newCompiler(files, mode),
			cold = build(compiler, "cold build");
		apply(compiler, files, entry.edit);
		var warm = build(compiler, "after the edit");
		if (mode == Plain)
			same(warm, build(newCompiler(files, mode), "fresh build of the edited sources"), "after the edit");
		apply(compiler, files, [for (path in entry.edit.keys()) path => entry.files.get(path)]);
		var restored = build(compiler, "after undoing the edit");
		// The cold build is a fresh build of the sources as they are again.
		if (mode == Plain)
			same(restored, cold, "after undoing the edit");
		return mode == Plain ? 4 : 3;
	}

	static function build(compiler:Compiler, step:String):haxe.io.Bytes
		return try {
			var result = compiler.compile("Main");
			// A live build's bytes are its patch against the session's module, not a program a fresh build writes.
			compiler.livePatching ? haxe.io.Bytes.alloc(0) : result.artifact.hashLink().hashLinkBytes().flatten();
		} catch (error:Dynamic) throw '$step: ${Std.string(error)}';

	static function same(warm:haxe.io.Bytes, fresh:haxe.io.Bytes, step:String):Void
		if (warm.compare(fresh) != 0)
			throw '$step: the warm module differs from a fresh one (${warm.length} and ${fresh.length} bytes)';

	/** Writes `changes` into `files` and into the session, removing the files whose text is null. */
	static function apply(compiler:Compiler, files:Map<String, String>, changes:Map<String, Null<String>>):Void {
		for (path => text in changes)
			if (text == null) {
				files.remove(path);
				compiler.remove(path);
			} else {
				files.set(path, text);
				compiler.update(path, text);
			}
		// A session asked to build again registers its source roots again, which is what makes it build rather than return its last
		// result.
		compiler.addSourceRoot("stdlib");
	}

	static function newCompiler(files:Map<String, String>, mode:CatalogueMode):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = mode == Live;
		compiler.options = new CompileOptions({checkReuse: true});
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}

	/** `text` with `from` replaced by `to`; `from` must occur, so an edit never silently leaves its program as it was. */
	static function swap(text:String, from:String, to:String):String {
		if (text.indexOf(from) < 0)
			throw 'the catalogue edits "$from", which its program does not contain';
		return StringTools.replace(text, from, to);
	}
}
