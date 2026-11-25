package compiler.semantic;

import compiler.syntax.CanonicalComparison;
import compiler.syntax.CanonicalComparison.PositionsCount;
import compiler.semantic.DeclarationFacts.FactAspect;
import compiler.syntax.Ast;

/** A module's canonical declarations, as `SemanticAssembly` keeps them (`ModuleState.canonical*`). */
typedef CanonicalContribution = {
	final aliases:Array<AstTypeAlias>;
	final enums:Array<AstEnum>;
	final abstracts:Array<AstAbstract>;
	final interfaces:Array<AstInterface>;
	final classes:Array<AstClass>;

	/** Every function of the module by its canonical name: module functions, and class and abstract methods. */
	final functions:Array<AstFunction>;
}

/**
 * Moves the facts of a module's declarations whose canonical form changed (`DeclarationFacts`), from the canonical declarations
 * the module had to those it has now, and names what each fact goes through: the shapes of the types its declaration names.
 * A fact a declaration added or removed changes too, and so does the fact of every declaration of its kind (`FactAspect.Kind`).
 * Only a class has members apart from its shape: for every other kind, the two facts change together.
 */
class DeclarationPrints {
	/** What a signature leaves out: its body, and its default values, which are compared with their positions. */
	static final SIGNATURE_PARTS = ["statements", "defaultValue"];

	/** What a class's members leave out: bodies and initializers, which are facts of their own. */
	static final MEMBER_PARTS = ["statements", "initializer"];

	/** What a class's shape leaves out: its members. */
	static final CLASS_SHAPE_PARTS = ["fields", "methods"];

	/** What an abstract's shape leaves out: method bodies, and its values, which are compared with their positions. */
	static final ABSTRACT_SHAPE_PARTS = ["statements", "values"];

	final facts:DeclarationFacts;

	/**
	 * Whether everything a body's canonical form is made from but its own text is the same as before: the names every module
	 * sees, and the module's imports and declarations. A body whose text and position are the same is then the same.
	 */
	final sameScope:Bool;

	final changedKinds:Map<String, Bool> = [];

	function new(facts:DeclarationFacts, sameScope:Bool) {
		this.facts = facts;
		this.sameScope = sameScope;
	}

	/**
	 * Moves the facts that differ between `before` (null for a module canonicalized for the first time) and `after`. `sameScope`
	 * says whether the module's canonicalization read the same names as when `before` was made.
	 */
	public static function update(facts:DeclarationFacts, before:Null<CanonicalContribution>,
			after:CanonicalContribution,
			sameScope:Bool):Void {
		var prints = new DeclarationPrints(facts, sameScope && before != null);
		prints.declarations(before, after);
		for (kind in prints.changedKinds.keys())
			facts.changed(facts.id(FactAspect.Kind, kind));
	}

	function declarations(before:Null<CanonicalContribution>, after:CanonicalContribution):Void {
		compareTypes(before == null ? [] : before.aliases, after.aliases, alias -> alias.name, (left, right) -> {
			facts.markExpanded(facts.id(FactAspect.Shape, either(left, right).name));
			var name = either(left, right).name;
			var changed = left == null || right == null
				|| !CanonicalComparison.aliases(left, right, PositionsCount.Ignored);
			var through = right == null ? null : shapesOf([right.type]), wireId = facts.id(FactAspect.WireShape, name);
			shapeChanged(name, DeclarationFacts.KIND_ALIASES, changed, through);
			if (changed)
				facts.changed(wireId);
			facts.setDependencies(wireId, through);
		});
		compareTypes(before == null ? [] : before.enums, after.enums, decl -> decl.name,
			(left, right) -> enumFacts(left, right));
		compareTypes(before == null ? [] : before.interfaces, after.interfaces, decl -> decl.name, (left, right) -> {
			shape(left, right, DeclarationFacts.KIND_INTERFACES,
				(left, right) -> CanonicalComparison.interfaces(left, right, PositionsCount.Ignored), decl -> decl.name,
				decl -> decl.bases.concat([for (field in decl.fields) if (field.type != null) field.type])
				.concat(signatureTypes(decl.methods)));
		});
		compareTypes(before == null ? [] : before.abstracts, after.abstracts, decl -> decl.name, (left, right) -> {
			facts.markExpanded(facts.id(FactAspect.Shape, either(left, right).name));
			var same = left != null && right != null
				&& CanonicalComparison.abstracts(left, right, PositionsCount.Ignored, ABSTRACT_SHAPE_PARTS)
				&& CanonicalComparison.abstractValues(left.values, right.values, PositionsCount.Lines);
			if (!same && ((left != null && left.values != null) || (right != null && right.values != null)))
				changedKinds.set(DeclarationFacts.KIND_ENUM_ABSTRACTS, true);
			var through = right == null
				? null : shapesOf([right.underlying].concat(right.fromTypes).concat(right.toTypes)
				.concat([for (field in right.fields) if (field.type != null) field.type])
				.concat(signatureTypes(right.methods)));
			var name = either(left, right).name;
			shapeChanged(name, DeclarationFacts.KIND_ABSTRACTS, !same, through);
			var wireId = facts.id(FactAspect.WireShape, name);
			if (!same)
				facts.changed(wireId);
			facts.setDependencies(wireId, right == null ? null : shapesOf([right.underlying]));
		});
		compareTypes(before == null ? [] : before.classes, after.classes, decl -> decl.name,
			(left, right) -> classFacts(left, right));
		compare(before == null ? [] : before.functions, after.functions, fn -> fn.name,
			(left, right) -> functionFacts(left, right));
	}

	/** Calls `each` with the declaration of every name in `before` or `after`, null where one side has none. */
	static function compare<T>(before:Array<T>, after:Array<T>, name:T->String, each:(Null<T>, Null<T>) -> Void):Void {
		var previous:Map<String, T> = [for (decl in before) name(decl) => decl];
		for (decl in after) {
			var key = name(decl);
			each(previous.get(key), decl);
			previous.remove(key);
		}
		for (decl in previous)
			each(decl, null);
	}

	/**
	 * `compare` for the declarations of types. A name one side declares and the other does not may be of another kind now (an
	 * interface made a class), which the declarations that name it go through (`DeclarationFacts.kindChanged`).
	 */
	function compareTypes<T>(before:Array<T>, after:Array<T>, name:T->String, each:(Null<T>, Null<T>) -> Void):Void
		compare(before, after, name, (left, right) -> {
			if (left == null || right == null)
				facts.kindChanged(facts.id(FactAspect.Shape, name(either(left, right))));
			each(left, right);
		});

	function shape<T>(left:Null<T>, right:Null<T>, kind:String, same:(T, T) -> Bool, name:T->String,
			types:T->Array<AstType>):Void {
		var changed = left == null || right == null || !same(left, right);
		shapeChanged(name(either(left, right)), kind, changed, right == null ? null : shapesOf(types(right)));
	}

	/** Moves the shape (and members) of non-class declaration `name` when `changed`, and names what they go through. */
	function shapeChanged(name:String, kind:String, changed:Bool, through:Null<Array<Int>>):Void {
		var shapeId = facts.id(FactAspect.Shape, name), membersId = facts.id(FactAspect.Members, name);
		if (changed) {
			facts.changed(shapeId);
			facts.changed(membersId);
			changedKinds.set(kind, true);
		}
		facts.setDependencies(shapeId, through);
		facts.setDependencies(membersId, through);
	}

	/**
	 * An enum's shape (its type parameters, metadata and conformances), its members (its constructors, and its methods with their
	 * lines) and each constructor alone: its index and parameters.
	 */
	function enumFacts(left:Null<AstEnum>, right:Null<AstEnum>):Void {
		var name = either(left, right).name,
			shapeId = facts.id(FactAspect.Shape, name),
			membersId = facts.id(FactAspect.Members, name);
		var sameShape = left != null && right != null
			&& CanonicalComparison.enums(left, right, PositionsCount.Ignored, ENUM_SHAPE_PARTS);
		var sameMembers = sameShape && left != null && right != null
			&& CanonicalComparison.enums(left, right, PositionsCount.Lines);
		if (left == null || right == null
			|| !CanonicalComparison.enums(left, right, PositionsCount.Ignored, ["methods"]))
			facts.changed(facts.id(FactAspect.WireShape, name));
		if (!sameShape)
			facts.changed(shapeId);
		if (!sameMembers) {
			facts.changed(membersId);
			changedKinds.set(DeclarationFacts.KIND_ENUMS, true);
		}
		var through = right == null
			? null : shapesOf([for (enumCase in right.cases) for (parameter in enumCase.params) parameter.type]);
		facts.setDependencies(shapeId, null);
		facts.setDependencies(membersId, through);
		facts.setDependencies(facts.id(FactAspect.WireShape, name), through);
		var previous:Map<String, {index:Int, enumCase:AstEnumCase}> = [];
		if (left != null)
			for (index in 0...left.cases.length)
				previous.set(left.cases[index].name, {index: index, enumCase: left.cases[index]});
		if (right != null)
			for (index in 0...right.cases.length) {
				var enumCase = right.cases[index],
					before = previous.get(enumCase.name),
					id = facts.id(FactAspect.Case, name + "." + enumCase.name);
				previous.remove(enumCase.name);
				if (before == null || before.index != index || !sameShape
					|| !CanonicalComparison.enumCases(before.enumCase, enumCase, PositionsCount.Ignored))
					facts.changed(id);
				facts.setDependencies(id, shapesOf([for (parameter in enumCase.params) parameter.type]));
			}
		for (caseName in previous.keys())
			facts.changed(facts.id(FactAspect.Case, name + "." + caseName));
		// An enum's methods are functions of their own, by their qualified names, which the module's functions list leaves out.
		compare(left == null
			|| left.methods == null ? [] : [for (method in left.methods) compiler.syntax.AstFunctions.withName(method,
			name + "." + method.name)],
			right == null
			|| right.methods == null ? [] : [for (method in right.methods) compiler.syntax.AstFunctions.withName(method,
			name + "." + method.name)],
			fn -> fn.name, (left, right) -> functionFacts(left, right));
	}

	/** What an enum's shape leaves out: its constructors and methods. */
	static final ENUM_SHAPE_PARTS = ["cases", "methods"];

	function classFacts(left:Null<AstClass>, right:Null<AstClass>):Void {
		var name = either(left, right).name,
			shapeId = facts.id(FactAspect.Shape, name),
			membersId = facts.id(FactAspect.Members, name);
		var sameShape = left != null && right != null
			&& CanonicalComparison.classes(left, right, PositionsCount.Ignored, CLASS_SHAPE_PARTS)
			&& (!isValueClass(right)
			|| CanonicalComparison.fieldList(left.fields, right.fields, PositionsCount.Ignored, MEMBER_PARTS));
		if (!sameShape) {
			facts.changed(shapeId);
			changedKinds.set(DeclarationFacts.KIND_CLASSES, true);
		}
		// JSON writes named record fields in declaration order, and decoders can use their initializers.
		var wireId = facts.id(FactAspect.WireShape, name);
		var wireFields = right == null ? [] : [for (field in right.fields) if (!field.isStatic) field];
		if (left == null || right == null
			|| !CanonicalComparison.fieldList([for (field in left.fields) if (!field.isStatic) field],
			wireFields, PositionsCount.Ignored))
			facts.changed(wireId);
		facts.setDependencies(wireId, shapesOf([for (field in wireFields) if (field.type != null) field.type]));
		var sameMembers = false;
		if (sameShape && left != null && right != null) {
			// Members are found by name, so their order is no part of them (a value type's field order is part of its shape).
			sameMembers = sameByName(left.fields, right.fields, field -> field.name,
				(previous, current) -> CanonicalComparison.fieldList([previous], [current], PositionsCount.Ignored,
				MEMBER_PARTS))
				&& sameByName(left.methods, right.methods, method -> method.name, sameMethodKind);
		}
		if (!sameMembers) {
			facts.changed(membersId);
			if (accessors(left) != accessors(right))
				changedKinds.set(DeclarationFacts.KIND_ACCESSORS, true);
			if (overrides(left) != overrides(right))
				changedKinds.set(DeclarationFacts.KIND_OVERRIDES, true);
		}
		var fields:Map<String, AstField> = left == null ? [] : [for (field in left.fields) field.name => field];
		if (right != null) {
			var named = right.interfaces.concat([for (field in right.fields) if (field.type != null) field.type]);
			if (right.base != null)
				named.push(right.base);
			facts.setDependencies(shapeId,
				shapesOf(isValueClass(right) ? named : right.base == null ? [] : [right.base]));
			facts.setDependencies(membersId, shapesOf(named));
			for (field in right.fields) {
				var previous = fields.get(field.name);
				fields.remove(field.name);
				initializer(name + "." + field.name, previous == null ? null : previous.initializer, field.initializer,
					previous == null ? null : previous.span, field.span);
			}
		}
		for (field in fields)
			initializer(name + "." + field.name, field.initializer, null, field.span, null);
	}

	/** A class's fields with accessors, with their accesses, in declaration order; empty for none or no class. */
	static function accessors(decl:Null<AstClass>):String {
		if (decl == null)
			return "";
		var text = new StringBuf();
		for (field in decl.fields)
			if (field.readAccess != null || field.writeAccess != null)
				text.add(field.name + ":" + Std.string(field.readAccess) + "," + Std.string(field.writeAccess) + ";");
		return text.toString();
	}

	/** A class's override methods by name, in declaration order; empty for none or no class. */
	static function overrides(decl:Null<AstClass>):String {
		if (decl == null)
			return "";
		var text = new StringBuf();
		for (method in decl.methods)
			if (method.isOverride == true)
				text.add(method.name + ";");
		return text.toString();
	}

	function initializer(key:String, left:Null<AstExpression>, right:Null<AstExpression>,
			leftSpan:Null<compiler.core.Source.SourceSpan>, rightSpan:Null<compiler.core.Source.SourceSpan>):Void {
		if (left == null && right == null)
			return;
		var id = facts.id(FactAspect.Initializer, key);
		if (left == null || right == null || !sameCode(leftSpan, rightSpan, false)
			&& !CanonicalComparison.expression(left, right, PositionsCount.Lines))
			facts.changed(id);
	}

	function functionFacts(left:Null<AstFunction>, right:Null<AstFunction>):Void {
		var name = either(left, right).name,
			signatureId = facts.id(FactAspect.Signature, name),
			bodyId = facts.id(FactAspect.Body, name);
		var sameSignature = left != null && right != null
			&& CanonicalComparison.functions(left, right, PositionsCount.Ignored, SIGNATURE_PARTS)
			&& CanonicalComparison.expressions([for (argument in left.arguments) argument.defaultValue],
			[for (argument in right.arguments) argument.defaultValue], PositionsCount.Lines);
		if (!sameSignature) {
			facts.changed(signatureId);
			changedKinds.set(KIND_FUNCTIONS, true);
		}
		// A function named as a setter, added or removed, is a setter some type may have (`DeclarationFacts.KIND_ACCESSORS`).
		if ((left == null || right == null) && StringTools.startsWith(name.substr(name.lastIndexOf(".") + 1), "set_"))
			changedKinds.set(DeclarationFacts.KIND_ACCESSORS, true);
		if (right != null)
			facts.setDependencies(signatureId, shapesOf(signatureTypes([right])));
		var generic = right != null && right.typeParameters != null && right.typeParameters.length > 0;
		if (left == null || right == null || !sameCode(left.span, right.span, generic)
			&& !CanonicalComparison.statements(left.statements, right.statements,
			generic ? PositionsCount.Offsets : PositionsCount.Lines))
			facts.changed(bodyId);
	}

	/** The kind of every function, read by code that searches the signature table. */
	public static inline final KIND_FUNCTIONS = "functions";

	/**
	 * Whether two spans of source hold the same text at the same line (and offset, for `generic`), in a scope that resolves
	 * every name as before: then their canonical forms are the same, without walking them.
	 */
	function sameCode(left:Null<compiler.core.Source.SourceSpan>, right:Null<compiler.core.Source.SourceSpan>,
			generic:Bool):Bool {
		if (!sameScope || left == null || right == null || left.file.path != right.file.path
			|| left.end - left.start != right.end - right.start)
			return false;
		if (generic && left.start != right.start)
			return false;
		if (left.file.text.length == 0 || right.file.text.length == 0)
			return false;
		if (left.file.lineAt(left.start) != right.file.lineAt(right.start))
			return false;
		return left.file.slice(left.start, left.end) == right.file.slice(right.start, right.end);
	}

	/**
	 * Whether two methods of a class are the same member: its name and kind. Their signatures are facts of their own
	 * (`FactAspect.Signature`), so a reader that names one method does not depend on the others.
	 */
	static function sameMethodKind(left:AstFunction, right:AstFunction):Bool
		return left.isStatic == right.isStatic && left.isPublic == right.isPublic && left.isOverride == right.isOverride
			&& left.isDynamic == right.isDynamic && left.isExtern == right.isExtern;

	/** Whether `left` and `right` hold the same members by name, each the same by `same`, in whatever order. */
	static function sameByName<T>(left:Array<T>, right:Array<T>, name:T->String, same:(T, T) -> Bool):Bool {
		if (left.length != right.length)
			return false;
		var previous:Map<String, T> = [for (member in left) name(member) => member];
		for (member in right) {
			var before = previous.get(name(member));
			if (before == null || !same(before, member))
				return false;
		}
		return true;
	}

	/** The declaration a comparison is of: the current one, or the one removed. */
	static function either<T>(left:Null<T>, right:Null<T>):T {
		if (right != null)
			return right;
		if (left != null)
			return left;
		throw new compiler.core.InternalError("A declaration comparison is of no declaration");
	}

	static function isValueClass(decl:AstClass):Bool {
		if (decl.isStruct == true)
			return true;
		for (metadata in decl.metadata)
			if (metadata.name == "value" || metadata.name == "repr")
				return true;
		return false;
	}

	static function signatureTypes(functions:Array<AstFunction>):Array<AstType> {
		var types:Array<AstType> = [];
		for (fn in functions) {
			for (argument in fn.arguments)
				types.push(argument.type);
			types.push(fn.result);
			if (fn.typeConstraints != null)
				for (constraint in fn.typeConstraints)
					types.push(constraint.type);
		}
		return types;
	}

	/** The shape facts of the declarations `types` name, each once; null for none. */
	function shapesOf(types:Array<AstType>):Null<Array<Int>> {
		var found:Array<Int> = [], seen:Map<String, Bool> = [];
		function add(name:String):Void
			if (!seen.exists(name)) {
				seen.set(name, true);
				found.push(facts.id(FactAspect.Shape, name));
			}
		function walk(type:AstType):Void
			switch type {
				case NativeAbstractType(declaration, _):
					add(declaration);
				case NamedType(name):
					add(name);
				case AppliedType(name, arguments):
					add(name);
					for (argument in arguments)
						walk(argument);
				case ArrayType(element), NullableType(element):
					walk(element);
				case MapType(key, value):
					walk(key);
					walk(value);
				case FunctionType(arguments, result, _):
					for (argument in arguments)
						walk(argument);
					walk(result);
				case AnonymousType(fields):
					for (field in fields)
						walk(field.type);
				case IntType, BoolType, FloatType, StringType, VoidType, InferredType, ErrorType(_):
			}
		for (type in types)
			walk(type);
		return found.length == 0 ? null : found;
	}
}
