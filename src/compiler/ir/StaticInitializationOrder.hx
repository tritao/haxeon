package compiler.ir;

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
 *   with a function expression is followed only from where it is read. A class already being placed is skipped, so a cycle keeps the order the walk found
 *   (Haxe warns "maybe loop in static generation").
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
	final walked:Map<String, Bool> = [];
	final order:Array<TypedClass> = [];

	/**
	 * `classes` in the order static initialization runs in. `classes` is in module order (`compareModules`, declaration order
	 * within a module); `initializers` holds a function per initialized static field (`Class.field`) that evaluates its
	 * initializer, and `program` the program's functions.
	 */
	public static function of(classes:Array<TypedClass>, initializers:Map<String, IrFunction>,
			program:Array<IrFunction>):Array<TypedClass> {
		var walk = new StaticInitializationOrder(classes, initializers, program);
		for (classDecl in classes)
			walk.place(classDecl.name);
		return walk.order;
	}

	function new(classList:Array<TypedClass>, initializers:Map<String, IrFunction>, program:Array<IrFunction>) {
		this.initializers = initializers;
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

	/** Haxe's `loop`: place `name` after what its static initialization reaches. */
	function place(name:String):Void {
		var classDecl = classes.get(name);
		if (classDecl == null || placing.exists(name))
			return;
		placing.set(name, true);
		if (classDecl.base != null)
			place(classDecl.base);
		walkMember(initFunction(name));
		// Haxe walks a class's statics in name order (a map keyed by name), which decides the order of what they reach.
		// A static whose initializer is a function expression is not walked from here, only where something reads it.
		var statics = [
			for (field in classDecl.fields)
				if (field.isStatic && !isFunctionExpression(field.initializer)) field.name
		];
		statics.sort(Reflect.compare);
		for (field in statics)
			walkMember(name + "." + field);
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
		for (block in fn.blocks)
			for (instruction in block.instructions)
				switch instruction.value {
					case GlobalGet(_, name), GlobalSet(name, _):
						var owner = staticOwners.get(name);
						if (owner != null) {
							place(owner);
							walkMember(name);
						}
					case NewObject(_, typeName):
						place(typeName);
					case Call(_, callee, _), StaticClosure(_, callee):
						reference(callee);
					case _:
				}
	}

	function reference(callee:String):Void {
		if (instanceMethods.exists(callee))
			return;
		var owner = memberOwners.get(callee);
		if (owner == null && !LambdaName.is(callee)) {
			// A module function (`pack.Mod.f`) is a member of its module, as its variables are: Haxe keeps both in one class.
			var dot = callee.lastIndexOf(".");
			if (dot > 0)
				owner = ModuleFields.storageName(callee.substr(0, dot));
		}
		if (owner != null)
			place(owner);
		// A lambda's body is part of the expression it is written in, and a generated helper stands for code Haxe has inline.
		walkMember(callee);
	}
}
