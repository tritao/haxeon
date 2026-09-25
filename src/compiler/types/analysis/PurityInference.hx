package compiler.types.analysis;

import compiler.syntax.Ast;

/**
 * Infers which static and module functions are pure: their bodies read state, allocate fresh
 * values, and call only pure functions, so calls to them keep mutable flow facts.
 *
 * The analysis is syntactic and conservative. Instance methods qualify only when no subclass
 * overrides them, since a call may otherwise dispatch to another body. Property reads depend on
 * their getters. `toString` runs through string conversion, so a function containing `+` depends on
 * every `toString` being pure. Abstract operators and implicit conversions can run at almost any
 * expression, so inference is used only when all of them are pure.
 */
class PurityInference {
	public static inline var TO_STRING = "$to-string";

	final signatures:Map<String, AstFunction>;
	final isAnnotatedPure:String->Bool;
	final isTypeName:String->Bool;
	final getters:Map<String, Array<String>> = [];
	final constructors:Map<String, Bool> = [];
	final classes:Map<String, AstClass>;
	final overridden:Map<String, Bool>;

	/** For an overridden method key, the concrete override bodies it also requires to be pure
	 * before a call through it can keep flow facts (see `dependenciesOf`).
	 */
	final overrideFamilies:Map<String, Array<String>>;

	function new(signatures:Map<String, AstFunction>, classes:Map<String, AstClass>, enums:Map<String, AstEnum>, isAnnotatedPure:String->Bool,
			isTypeName:String->Bool) {
		this.signatures = signatures;
		this.isAnnotatedPure = isAnnotatedPure;
		this.isTypeName = isTypeName;
		this.classes = classes;
		overridden = OverrideAnalysis.overriddenMethods(classes);
		overrideFamilies = OverrideAnalysis.overrideFamilies(classes, overridden);
		for (className => classDecl in classes)
			for (field in classDecl.fields)
				if (field.readAccess == GetAccess || field.readAccess == DynamicAccess) {
					var accessors = getters.get(field.name);
					if (accessors == null) {
						accessors = [];
						getters.set(field.name, accessors);
					}
					// A dynamic accessor can be replaced at run time, so it never counts as pure.
					accessors.push(field.readAccess == GetAccess ? className + ".get_" + field.name : "$dynamic-accessor");
				}
		for (enumDecl in enums)
			for (enumCase in enumDecl.cases)
				constructors.set(enumCase.name, true);
	}

	/** Returns inferred-pure static and module function keys. */
	public static function infer(signatures:Map<String, AstFunction>, classes:Map<String, AstClass>, abstracts:Map<String, AstAbstract>,
			enums:Map<String, AstEnum>, isAnnotatedPure:String->Bool, isTypeName:String->Bool):Map<String, Bool> {
		var inference = new PurityInference(signatures, classes, enums, isAnnotatedPure, isTypeName),
			dependencies:Map<String, Map<String, Bool>> = [],
			operatorMethods:Array<String> = [],
			stringMethods:Array<String> = [];
		for (name => fn in signatures) {
			if (fn.isExtern == true || isAnnotatedPure(name))
				continue;
			var owner = compiler.QualifiedName.parent(name),
				operatorMethod = isOperatorMethod(fn, owner, abstracts),
				stringConversion = !fn.isStatic && fn.name == "toString" && owner != null && classes.exists(owner);
			if (operatorMethod)
				operatorMethods.push(name);
			if (stringConversion)
				stringMethods.push(name);
			if (!operatorMethod && !stringConversion && !inference.isCandidate(name))
				continue;
			var found = inference.dependenciesOf(fn, name);
			if (found != null)
				dependencies.set(name, found);
		}
		for (name in operatorMethods)
			if (!dependencies.exists(name))
				return [];
		var stringsPure = true;
		// Greatest fixpoint: recursive functions without effects remain pure.
		var changed = true;
		while (changed) {
			changed = false;
			stringsPure = true;
			for (name in stringMethods)
				if (!dependencies.exists(name))
					stringsPure = false;
			for (name => needs in dependencies) {
				for (dependency in needs.keys())
					if (dependency == TO_STRING ? !stringsPure : !dependencies.exists(dependency) && !isAnnotatedPure(dependency)) {
						dependencies.remove(name);
						changed = true;
						break;
					}
			}
			for (name in operatorMethods)
				if (!dependencies.exists(name))
					return [];
		}
		var result:Map<String, Bool> = [];
		for (name in dependencies.keys())
			if (inference.isCandidate(name))
				result.set(name, true);
		return result;
	}

	static function isOperatorMethod(fn:AstFunction, owner:Null<String>, abstracts:Map<String, AstAbstract>):Bool {
		if (owner == null || !abstracts.exists(owner) || fn.metadata == null)
			return false;
		for (entry in fn.metadata)
			if (entry.name == "op"
				|| entry.name == "arrayAccess"
				|| entry.name == "from"
				|| entry.name == "to"
				|| entry.name == "resolve")
				return true;
		return false;
	}

	/** Callee keys the body depends on, or null when the body has a direct effect.
	 *
	 * An overridden method also depends on every concrete override in its subclasses: a virtual
	 * call through it might run one of them instead, so its own answer is only trustworthy once
	 * theirs is too. Injecting those keys here lets the ordinary fixpoint in `infer` decide it,
	 * exactly as it already does for an ordinary callee.
	 */
	function dependenciesOf(fn:AstFunction, name:String):Null<Map<String, Bool>> {
		var walker = new PurityWalker(this, name);
		walker.declare("this");
		for (argument in fn.arguments) {
			if (argument.defaultValue != null && !walker.value(argument.defaultValue))
				return null;
			walker.declare(argument.name, PurityWalker.isNumericType(argument.type), classNameOfType(argument.type),
				PurityWalker.isIterableType(argument.type));
		}
		if (!walker.statements(fn.statements))
			return null;
		var result = walker.dependencies;
		var family = overrideFamilies.get(name);
		if (family != null)
			for (overrideKey in family)
				result.set(overrideKey, true);
		return result;
	}

	/** The known concrete class of a declared type, when it names a class this program declares -
	 * only then can a call through a value of that type be resolved to a specific method key.
	 */
	public function classNameOfType(type:Null<AstType>):Null<String>
		return switch type {
			case NamedType(name) if (classes.exists(name)): name;
			case AppliedType(name, _) if (classes.exists(name)): name;
			default: null;
		};

	public function resolveCall(name:String, functionName:String):Null<String> {
		var keys = name.indexOf(".") >= 0 ? [name] : [sibling(functionName, name), name];
		for (key in keys)
			if (signatures.exists(key) || isAnnotatedPure(key))
				return key;
		return null;
	}

	/** A method on the enclosing class, called through `this`. */
	public function resolveOwnMethod(name:String, functionName:String):Null<String> {
		var key = sibling(functionName, name);
		return signatures.exists(key) ? key : null;
	}

	public function resolveStatic(typeName:String, method:String, functionName:String):Null<String> {
		var owner = compiler.QualifiedName.parent(functionName),
			packageName = owner == null ? null : compiler.QualifiedName.parent(owner);
		for (candidate in [
			typeName + "." + method,
			packageName == null ? null : packageName + "." + typeName + "." + method
		])
			if (candidate != null && (isAnnotatedPure(candidate) || (signatures.exists(candidate) && signatures.get(candidate).isStatic)))
				return candidate;
		return null;
	}

	/** A method called on a receiver whose static type is a known class of this program. */
	public function resolveInstance(className:String, method:String):Null<String> {
		var candidate = className + "." + method;
		return signatures.exists(candidate) ? candidate : null;
	}

	/** Functions whose calls always reach the analysed body: statics, module functions, and
	 * instance methods. An overridden instance method is also a candidate - `dependenciesOf`
	 * makes its acceptance depend on every concrete override sharing the same answer.
	 */
	public function isCandidate(key:String):Bool {
		var fn = signatures.get(key);
		if (fn == null || fn.isExtern == true)
			return isAnnotatedPure(key);
		var owner = compiler.QualifiedName.parent(key);
		if (fn.isStatic || owner == null || !isTypeName(owner))
			return true;
		return classes.exists(owner) && fn.name != "new";
	}

	/** Getter keys a property read depends on; null when the name has no getter. */
	public function getterDependencies(name:String):Null<Array<String>>
		return getters.get(name);

	/** The declared type of `owner`'s own field named `name`, when it has one. */
	public function ownFieldType(owner:Null<String>, name:String):Null<AstType> {
		if (owner == null)
			return null;
		var classDecl = classes.get(owner);
		if (classDecl == null)
			return null;
		for (field in classDecl.fields)
			if (field.name == name)
				return field.type;
		return null;
	}

	public function isConstructor(name:String):Bool
		return constructors.exists(name);

	static function sibling(functionName:String, name:String):String {
		var owner = compiler.QualifiedName.parent(functionName);
		return owner == null ? name : owner + "." + name;
	}
}

/** What is known, purely syntactically, about one local: whether `+` on it can skip `toString`,
 * and whether a call or a loop through it reaches only compiler-owned code.
 */
private typedef LocalFact = {
	final numeric:Bool;
	final className:Null<String>;
	final iterable:Bool;
}

/** Walks one body with lexical locals, collecting callees and rejecting direct effects. */
private class PurityWalker {
	public final dependencies:Map<String, Bool> = [];

	final inference:PurityInference;
	final functionName:String;

	/** Local name to what is known about it; see `LocalFact`. */
	final scopes:Array<Map<String, LocalFact>> = [[]];

	public function new(inference:PurityInference, functionName:String) {
		this.inference = inference;
		this.functionName = functionName;
	}

	public function declare(name:String, numeric:Bool = false, ?className:String, iterable:Bool = false):Void
		scopes[scopes.length - 1].set(name, {numeric: numeric, className: className, iterable: iterable});

	public static function isNumericType(type:Null<AstType>):Bool
		return switch type {
			case IntType, FloatType: true;
			case NamedType("Int64"): true;
			default: false;
		};

	/** `Array<T>`/`Map<K, V>` values are backed by a runtime iterator: looping over one runs no
	 * user code, however its elements were produced.
	 */
	public static function isIterableType(type:Null<AstType>):Bool
		return switch type {
			case ArrayType(_), MapType(_, _): true;
			default: false;
		};

	function localFact(name:String):Null<LocalFact> {
		var index = scopes.length;
		while (index > 0) {
			index--;
			if (scopes[index].exists(name))
				return scopes[index].get(name);
		}
		return null;
	}

	function isNumericLocal(name:String):Bool {
		var fact = localFact(name);
		return fact != null && fact.numeric;
	}

	/** The known concrete class of a local, if any - lets `obj.m()` resolve to a method key
	 * instead of unconditionally rejecting the call.
	 */
	function classNameOfLocal(name:String):Null<String> {
		var fact = localFact(name);
		return fact == null ? null : fact.className;
	}

	function isIterableLocal(name:String):Bool {
		var fact = localFact(name);
		return fact != null && fact.iterable;
	}

	/** Syntactically numeric: numeric literals and locals, and arithmetic over them. */
	function isNumeric(value:AstExpression):Bool
		return switch value {
			case IntegerLiteral(_, _), FloatLiteral(_, _): true;
			case Variable(name, _): isNumericLocal(name);
			case Add(left, right, _), Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _): isNumeric(left) && isNumeric(right);
			case Negate(inner, _): isNumeric(inner);
			default: false;
		};

	public function value(expression:AstExpression):Bool
		return this.expression(expression);

	function isLocal(name:String):Bool {
		for (scope in scopes)
			if (scope.exists(name))
				return true;
		return false;
	}

	function scoped(action:() -> Bool):Bool {
		scopes.push([]);
		var result = action();
		scopes.pop();
		return result;
	}

	public function statements(body:Array<AstStatement>):Bool
		return scoped(() -> {
			for (statement in body)
				if (!this.statement(statement))
					return false;
			return true;
		});

	function statement(value:AstStatement):Bool {
		return switch value {
			case ErrorStatement(_): false;
			case UninitializedDeclaration(name, type, _):
				declare(name, isNumericType(type), classNameOfType(type), isIterableType(type));
				true;
			case VarDeclaration(name, type, initializer, _):
				var pure = expression(initializer);
				if (type == null || type == InferredType)
					declare(name, isNumeric(initializer), null, isIterableInitializer(initializer));
				else
					declare(name, isNumericType(type), classNameOfType(type), isIterableType(type));
				pure;
			case Assignment(name, value, _): isLocal(name) && expression(value);
			case Increment(name, _, _): isLocal(name);
			case IndexAssignment(_, _, _, _), FieldAssignment(_, _, _, _): false;
			case Return(value, _), Throw(value, _), Expression(value, _): expression(value);
			case ReturnVoid(_), Break(_), Continue(_): true;
			case Try(body, catches, _):
				if (!statements(body))
					return false;
				for (handler in catches)
					if (!scoped(() -> {
						declare(handler.name);
						return statements(handler.statements);
					}))
						return false;
				true;
			case If(test, yes, no, _): expression(test) && statements(yes) && statements(no);
			case While(test, body, _), DoWhile(body, test, _): expression(test) && statements(body);
			case ForIn(key, item, iterable, body, _): isPureIterable(iterable) && expression(iterable) && scoped(() -> {
					declare(key, true);
					if (item != null)
						declare(item);
					return statements(body);
				});
			case Switch(subject, cases, fallback, _, _):
				if (!expression(subject) || !statements(fallback))
					return false;
				for (entry in cases)
					if (!scoped(() -> {
						bindPattern(entry.value);
						return (entry.guard == null || expression(entry.guard)) && statements(entry.statements);
					}))
						return false;
				true;
		};
	}

	function expression(value:AstExpression):Bool {
		return switch value {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_), Unreachable(_), EmptyExpression(_),
				NativeLayoutQuery(_, _, _, _), NewMap(_, _, _), Lambda(_, _, _):
				true;
			case ErrorExpression(_), ClosureCall(_, _, _), New(_, _, _), NewGeneric(_, _, _, _), MapComprehension(_, _, _, _, _, _, _):
				false;
			case Variable(name, _): isLocal(name) || readsProperty(name);
			case Member(object, name, _): readsProperty(name) && expression(object);
			case Add(left, right, _): // `+` may convert an object operand through its toString, unless both sides are numbers.
				if (!isNumeric(left) || !isNumeric(right)) dependencies.set(PurityInference.TO_STRING, true); expression(left) && expression(right);
			case Sub(left, right, _), Mul(left, right, _), Div(left, right, _), Mod(left, right, _), BitAnd(left, right, _), BitXor(left, right, _),
				BitOr(left, right, _), ShiftLeft(left, right, _), ShiftRight(left, right, _), UnsignedShiftRight(left, right, _), Less(left, right, _),
				LessEqual(left, right, _), Greater(left, right, _), GreaterEqual(left, right, _), Equal(left, right, _), NotEqual(left, right, _),
				And(left, right, _), Or(left, right, _), Range(left, right, _), Index(left, right, _): expression(left) && expression(right);
			case Negate(value, _), Not(value, _), ThrowExpression(value, _), Cast(value, _, _), NewArray(_, value, _): expression(value);
			case Conditional(test, yes, no, _): expression(test) && expression(yes) && expression(no);
			case BlockExpression(body, result, _):
				scoped(() -> {
					for (statement in body)
						if (!this.statement(statement))
							return false;
					return expression(result);
				});
			case SwitchExpression(subject, cases, fallback, _):
				if (!expression(subject) || (fallback != null && !expression(fallback)))
					return false;
				for (entry in cases)
					if (!scoped(() -> {
						bindPattern(entry.value);
						return (entry.guard == null || expression(entry.guard)) && expression(entry.result);
					}))
						return false;
				true;
			case ObjectLiteral(fields, _):
				for (field in fields)
					if (!expression(field.value))
						return false;
				true;
			case ArrayLiteral(values, _): all(values);
			case MapLiteral(entries, _):
				for (entry in entries)
					if (!expression(entry.key) || !expression(entry.value))
						return false;
				true;
			case ArrayComprehension(key, item, iterable, filter, result, _): isPureIterable(iterable) && expression(iterable) && scoped(() -> {
					declare(key);
					if (item != null)
						declare(item);
					return (filter == null || expression(filter)) && expression(result);
				});
			case Call(name, arguments, _):
				if (!all(arguments))
					return false;
				if (!isLocal(name) && inference.isConstructor(name))
					return true;
				var key = isLocal(name) ? null : inference.resolveCall(name, functionName);
				if (key == null || !inference.isCandidate(key))
					return false;
				dependencies.set(key, true);
				true;
			case MethodCall(object, name, arguments, _):
				var key = switch object {
					case Variable("this", _): inference.resolveOwnMethod(name, functionName);
					case Variable(typeName, _) if (!isLocal(typeName)): inference.resolveStatic(typeName, name, functionName);
					case Variable(local, _) if (classNameOfLocal(local) != null): inference.resolveInstance(classNameOfLocal(local), name);
					case Member(Variable("this", _), field, _) if (fieldClassName(field) != null && readsProperty(field)):
						inference.resolveInstance(fieldClassName(field), name);
					default: null;
				};
				if (key != null && !inference.isCandidate(key))
					key = null;
				if (key == null || !all(arguments))
					return false;
				dependencies.set(key, true);
				true;
			case PostfixIncrement(target, _, _):
				switch target {
					case Variable(name, _): isLocal(name);
					default: false;
				}
		};
	}

	/** A property read runs its getter; plain field reads have no effect. */
	function readsProperty(name:String):Bool {
		var accessors = inference.getterDependencies(name);
		if (accessors == null)
			return true;
		for (accessor in accessors) {
			if (!inference.isCandidate(accessor))
				return false;
			dependencies.set(accessor, true);
		}
		return true;
	}

	function all(values:Array<AstExpression>):Bool {
		for (value in values)
			if (!expression(value))
				return false;
		return true;
	}

	/** Pattern names are fresh locals; constructors and literals in patterns have no effect. */
	function bindPattern(pattern:AstExpression):Void {
		switch pattern {
			case Variable(name, _):
				declare(name);
			case Call(_, arguments, _):
				for (argument in arguments)
					bindPattern(argument);
			case ArrayLiteral(values, _):
				for (value in values)
					bindPattern(value);
			case ObjectLiteral(fields, _):
				for (field in fields)
					bindPattern(field.value);
			case Or(left, right, _):
				bindPattern(left);
				bindPattern(right);
			default:
		}
	}

	function classNameOfType(type:Null<AstType>):Null<String>
		return inference.classNameOfType(type);

	/** `new T(...)` always taints its enclosing statement impure (constructors are not analysed),
	 * so tracking a class name from one would never be consulted; only literal shapes are worth
	 * inferring here.
	 */
	function isIterableInitializer(initializer:AstExpression):Bool
		return switch initializer {
			case ArrayLiteral(_, _), MapLiteral(_, _), NewArray(_, _, _), NewMap(_, _, _): true;
			default: false;
		};

	/** A loop runs no user code when its iterable is a numeric range, a fresh array/map literal,
	 * or a value already known to be `Array<T>`/`Map<K, V>` - a local of that type, or one of the
	 * enclosing class's own fields declared with that type.
	 */
	function isPureIterable(iterable:AstExpression):Bool
		return switch iterable {
			case Range(_, _, _), ArrayLiteral(_, _), MapLiteral(_, _): true;
			case Variable(name, _): isIterableLocal(name);
			case Member(Variable("this", _), field, _): fieldIsIterable(field);
			default: false;
		};

	/** The known concrete class of `this`'s own field, when its declared type names one. */
	function fieldClassName(field:String):Null<String>
		return classNameOfType(inference.ownFieldType(compiler.QualifiedName.parent(functionName), field));

	function fieldIsIterable(field:String):Bool
		return PurityWalker.isIterableType(inference.ownFieldType(compiler.QualifiedName.parent(functionName), field));
}
