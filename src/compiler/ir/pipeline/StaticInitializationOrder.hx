package compiler.ir.pipeline;

import compiler.core.Diagnostic;
import compiler.core.DiagnosticCode;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.reuse.IrFunctionMemo;
import compiler.semantic.AbstractStatics;
import compiler.semantic.LambdaName;
import compiler.semantic.ModuleFields;
import compiler.types.TypedAst.TypedClass;
import compiler.types.TypedAst.TypedExpression;

/**
 * The order static initialization runs in, as Haxe 4.3.7 orders it on HashLink (`Finalization.sort_types`, then genhl's
 * `generate_static_init`):
 *
 * - Modules in path order (`compareModules`), each module's classes in declaration order, its module-level variables and
 *   functions (Haxe's `Mod_Fields_`, Haxeon's `ModuleFields` class) last.
 * - A class comes after the classes its static initialization reaches: its base class, and every class whose static field,
 *   static method or constructor its `__init__` and static initializers use, following the initializers of those fields, the
 *   bodies of those methods and constructors, and the lambdas written in them (not instance methods). A static initialized
 *   with a function expression is followed only from where it is read. A class already being placed is skipped, so a cycle keeps
 *   the order the walk found; reaching it from another class's walk is Haxe's "maybe loop in static generation" warning
 *   (`loops`).
 * - Every class's `__init__` runs first, in that order; then every class's static initializers, in that order, each class's in
 *   declaration order. Nothing is reordered by what an initializer reads: one that reads a static set later reads its default
 *   value (0, false or null), as in Haxe.
 *
 * The walk is over IR: a static field is its global, a static method or constructor a call or closure, a lambda its function.
 */
class StaticInitializationOrder {
	/** Haxe's order of module paths: package by package (a package before its subpackages), then the module name. */
	public static function compareModules(left:String, right:String):Int {
		var leftParts = left.split("."), rightParts = right.split(".");
		var leftName = leftParts.pop(), rightName = rightParts.pop();
		var index = 0;
		while (index < leftParts.length && index < rightParts.length) {
			var order = Reflect.compare(leftParts[index], rightParts[index]);
			if (order != 0)
				return order;
			index++;
		}
		if (leftParts.length != rightParts.length)
			return leftParts.length - rightParts.length;
		return Reflect.compare(leftName, rightName);
	}

	/**
	 * W1002, Haxe's warning (WStaticInitOrder) for a class its static initialization order reaches in a loop, at the class's
	 * declaration: its statics may be read before they are set.
	 */
	public static function loopWarning(classDecl:TypedClass):Diagnostic
		return new Diagnostic(DiagnosticCode.STATIC_INIT_CYCLE,
			"maybe loop in static generation of " + AbstractStatics.displayOwner(classDecl.name),
			classDecl.span, Warning);

	/** The name of the `__init__` function of `className`. */
	public static inline function initFunction(className:String):String
		return className + ".__init__";

	final classes:Map<String, TypedClass> = [];

	/** Static field globals (`Class.field`) to their class. */
	final staticOwners:Map<String, String> = [];

	/** Static methods and constructors to their class. */
	final memberOwners:Map<String, String> = [];

	/** Instance methods: Haxe does not follow them. */
	final instanceMethods:Map<String, Bool> = [];

	final initializers:Map<String, IrFunction>;
	final functions:Map<String, IrFunction>;
	final placing:Map<String, Bool> = [];
	final placed:Map<String, Bool> = [];
	final walked:Map<String, Bool> = [];
	final order:Array<TypedClass> = [];

	/** The classes being placed, innermost last: Haxe's `p`, the class whose walk reaches the others. */
	final generating:Array<String> = [];

	/** Each class reached while it was being placed, from another class's walk, in the order the walk reached it. */
	final loops:Array<TypedClass> = [];

	/**
	 * `classes` in the order static initialization runs in. `classes` is in module order (`compareModules`, declaration order
	 * within a module); `initializers` holds a function per initialized static field (`Class.field`) that evaluates its
	 * initializer, and `program` the program's functions.
	 */
	public static function of(classes:Array<TypedClass>, initializers:Map<String, IrFunction>,
			program:Array<IrFunction>, ?memo:IrFunctionMemo<IrStaticReferences>):{
				order:Array<TypedClass>,
				loops:Array<TypedClass>
			} {
		var walk = new StaticInitializationOrder(classes, initializers, program, memo);
		for (classDecl in classes)
			walk.place(classDecl.name);
		return {order: walk.order, loops: walk.loops};
	}

	/** What each function references (`IrStaticReferences`), kept by the session while the function is the same object. */
	final memo:Null<IrFunctionMemo<IrStaticReferences>>;

	function new(classList:Array<TypedClass>, initializers:Map<String, IrFunction>, program:Array<IrFunction>,
			memo:Null<IrFunctionMemo<IrStaticReferences>>) {
		this.initializers = initializers;
		this.memo = memo;
		functions = [for (fn in program) fn.name => fn];
		for (classDecl in classList) {
			classes.set(classDecl.name, classDecl);
			for (field in classDecl.fields)
				if (field.isStatic)
					staticOwners.set(classDecl.name + "." + field.name, classDecl.name);
			for (method in classDecl.methods)
				if (method.isStatic || method.isConstructor)
					memberOwners.set(method.name, classDecl.name);
				else {
					instanceMethods.set(method.name, true);
					if (method.dispatchEntry != null)
						instanceMethods.set(method.dispatchEntry, true);
				}
		}
	}

	/**
	 * Haxe's `loop`: place `name` after what its static initialization reaches. A class still being placed is not placed again;
	 * reached from another class's walk (Haxe's `loop_class`, which skips the class itself) it is a loop.
	 */
	function place(name:String):Void {
		var classDecl = classes.get(name);
		if (classDecl == null)
			return;
		if (placing.exists(name)) {
			if (!placed.exists(name) && generating[generating.length - 1] != name)
				loops.push(classDecl);
			return;
		}
		placing.set(name, true);
		generating.push(name);
		if (classDecl.base != null)
			place(classDecl.base);
		walkMember(initFunction(name));
		// Haxe walks a class's statics in name order (a map keyed by name), which decides the order of what they reach.
		// A static whose initializer is a function expression is not walked from here, only where something reads it. Haxe's
		// `walk_class` walks them without marking them walked, so a read from elsewhere walks one again, once, from there.
		var statics = [
			for (field in classDecl.fields)
				if (field.isStatic && field.isDynamicMethod != true
				&& !isFunctionExpression(field.initializer)) field.name
		];
		statics.sort(Reflect.compare);
		for (field in statics) {
			var initializer = initializers.get(name + "." + field);
			if (initializer != null)
				walk(initializer);
		}
		generating.pop();
		placed.set(name, true);
		order.push(classDecl);
	}

	static function isFunctionExpression(initializer:Null<TypedExpression>):Bool
		return initializer != null && switch initializer.expression {
			case TLambda(_, _, _): true;
			case TToDynamic(value), TNullableWrap(value): isFunctionExpression(value);
			case _: false;
		};

	/** Haxe's `walk_static_field`: the initializer or body of a static member, once. */
	function walkMember(member:String):Void {
		if (walked.exists(member))
			return;
		walked.set(member, true);
		var fn = initializers.get(member);
		if (fn == null)
			fn = functions.get(member);
		if (fn != null)
			walk(fn);
	}

	function walk(fn:IrFunction):Void {
		var references = memo == null ? null : memo.get(fn);
		if (references == null) {
			references = IrStaticReferences.of(fn);
			if (memo != null)
				memo.set(fn, references);
		}
		for (index in 0...references.kinds.length) {
			var name = references.names[index];
			switch references.kinds[index] {
				case IrStaticReferences.GLOBAL:
					var owner = staticOwners.get(name);
					if (owner != null) {
						place(owner);
						walkMember(name);
					}
				case IrStaticReferences.CREATED:
					place(name);
				default:
					reference(name);
			}
		}
	}

	function reference(callee:String):Void {
		if (instanceMethods.exists(callee))
			return;
		var owner = memberOwners.get(callee);
		if (owner == null && !LambdaName.is(callee)) {
			// A module function (`pack.Mod.f`) is a member of its module, as its variables are: Haxe keeps both in one class. So is
			// an abstract's static method (`pack.Counter.total`) of the abstract, whose statics its storage class keeps.
			var dot = callee.lastIndexOf(".");
			if (dot > 0) {
				var prefix = callee.substr(0, dot), statics = AbstractStatics.storageName(prefix);
				owner = classes.exists(statics) ? statics : ModuleFields.storageName(prefix);
			}
		}
		if (owner != null)
			place(owner);
		// A lambda's body is part of the expression it is written in, and a generated helper stands for code Haxe has inline.
		walkMember(callee);
	}
}

/**
 * What the walk of static initialization order reads of one function, in its order: the globals it reads or writes, the classes it
 * creates and the functions it calls or closes over. It depends on the function alone, so a session keeps it while the function is
 * the same object, and a function kept as its body alone is read from the body.
 */
class IrStaticReferences {
	public static inline final GLOBAL = 0;
	public static inline final CREATED = 1;
	public static inline final CALLED = 2;

	public final kinds:Array<Int> = [];
	public final names:Array<String> = [];

	function new() {}

	public static function of(fn:IrFunction):IrStaticReferences {
		var references = new IrStaticReferences(), body = fn.body;
		if (body != null) {
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.GlobalGet, IrOpcode.GlobalSet:
							references.add(GLOBAL, body.symbol(row).name);
						case IrOpcode.NewObject:
							references.add(CREATED, body.symbol(row).name);
						case IrOpcode.Call, IrOpcode.StaticClosure:
							references.add(CALLED, body.symbol(row).name);
						default:
					}
					row = body.nextRow(row);
				}
			}
			return references;
		}
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case GlobalGet(_, name), GlobalSet(name, _):
						references.add(GLOBAL, name);
					case NewObject(_, typeName):
						references.add(CREATED, typeName);
					case Call(_, callee, _), StaticClosure(_, callee):
						references.add(CALLED, callee.name);
					case _:
				}
		return references;
	}

	inline function add(kind:Int, name:String):Void {
		kinds.push(kind);
		names.push(name);
	}
}
