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

	function new(signatures:Map<String, AstFunction>, classes:Map<String, AstClass>, enums:Map<String, AstEnum>, isAnnotatedPure:String->Bool,
			isTypeName:String->Bool) {
		this.signatures = signatures;
		this.isAnnotatedPure = isAnnotatedPure;
		this.isTypeName = isTypeName;
		this.classes = classes;
		overridden = OverrideAnalysis.overriddenMethods(classes);
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

	/** Callee keys the body depends on, or null when the body has a direct effect. */
	function dependenciesOf(fn:AstFunction, name:String):Null<Map<String, Bool>> {
		var walker = new PurityWalker(this, name);
		walker.declare("this");
		for (argument in fn.arguments) {
			if (argument.defaultValue != null && !walker.value(argument.defaultValue))
				return null;
			walker.declare(argument.name, PurityWalker.isNumericType(argument.type));
		}
		if (!walker.statements(fn.statements))
			return null;
		return walker.dependencies;
	}

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

	/** Functions whose calls always reach the analysed body: statics, module functions, and
	 * instance methods of classes that no subclass overrides.
	 */
	public function isCandidate(key:String):Bool {
		var fn = signatures.get(key);
		if (fn == null || fn.isExtern == true)
			return isAnnotatedPure(key);
		var owner = compiler.QualifiedName.parent(key);
		if (fn.isStatic || owner == null || !isTypeName(owner))
			return true;
		return classes.exists(owner) && fn.name != "new" && !overridden.exists(key);
	}

	/** Getter keys a property read depends on; null when the name has no getter. */
	public function getterDependencies(name:String):Null<Array<String>>
		return getters.get(name);

	public function isConstructor(name:String):Bool
		return constructors.exists(name);

	static function sibling(functionName:String, name:String):String {
		var owner = compiler.QualifiedName.parent(functionName);
		return owner == null ? name : owner + "." + name;
	}
}

/** Walks one body with lexical locals, collecting callees and rejecting direct effects. */
private class PurityWalker {
	public final dependencies:Map<String, Bool> = [];

	final inference:PurityInference;
	final functionName:String;

	/** Local name to whether it is known numeric; numeric `+` never converts through toString. */
	final scopes:Array<Map<String, Bool>> = [[]];

	public function new(inference:PurityInference, functionName:String) {
		this.inference = inference;
		this.functionName = functionName;
	}

	public function declare(name:String, numeric:Bool = false):Void
		scopes[scopes.length - 1].set(name, numeric);

	public static function isNumericType(type:Null<AstType>):Bool
		return switch type {
			case IntType, FloatType: true;
			case NamedType("Int64"): true;
			default: false;
		};

	function isNumericLocal(name:String):Bool {
		var index = scopes.length;
		while (index > 0) {
			index--;
			if (scopes[index].exists(name))
				return scopes[index].get(name);
		}
		return false;
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
				declare(name, isNumericType(type));
				true;
			case VarDeclaration(name, type, initializer, _):
				var pure = expression(initializer);
				declare(name, type == null || type == InferredType ? isNumeric(initializer) : isNumericType(type));
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
			case ForIn(key, item, iterable, body, _): isRange(iterable) && expression(iterable) && scoped(() -> {
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
			case ArrayComprehension(key, item, iterable, filter, result, _): isRange(iterable) && expression(iterable) && scoped(() -> {
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

	static function isRange(iterable:AstExpression):Bool
		return switch iterable {
			case Range(_, _, _): true;
			default: false;
		};
}
