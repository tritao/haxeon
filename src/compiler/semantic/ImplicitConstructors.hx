package compiler.semantic;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstVisibility;

/** The constructor a class exposes: its argument list, and the type parameters those arguments are written in. */
typedef ProvidedConstructor = {
	final arguments:Array<AstArgument>;
	final typeParameters:Array<String>;
}

/**
 * A class that declares no constructor has the constructor of its base class, with the same arguments; constructing it
 * runs the base constructor and then the field initializers of every class in the chain. Nothing runs them for a class
 * without a constructor of its own, so each such class gets `new(arguments) { super(arguments); }` before typing, and
 * every later stage sees an ordinary explicit constructor.
 *
 * A base class that only has field initializers has a constructor too (typing supplies it), taking no arguments.
 *
 * A struct that declares no constructor gets a memberwise one: a parameter per stored field, in declaration order, whose
 * default is the field's initializer, and a body that stores each; it does not run the initializers, since it stores every
 * field (`ProgramTyper`). A literal initializer stays on its field too, where native descriptors and wire codecs read it as
 * the field's default; any other (`[]`, `new Point(1.0)`), which a struct field could not hold before, is the
 * constructor's default only. A call names the parameters as any arguments (`new Size(w: 4)`). A field without an
 * initializer is a required parameter: no struct is built with fields it did not set.
 *
 * Three kinds of struct keep the constructor typing supplies, which runs the initializers and leaves other fields zero: one
 * with a stored field without a type annotation, whose type is its initializer's; an annotation struct, which metadata
 * builds and which declares no methods; and a native-layout one (a native scalar field, `@:repr("C")`, or such a struct as
 * a field), since native-layout values cannot be passed as parameters yet.
 */
class ImplicitConstructors {
	/** The metadata a struct's memberwise constructor carries, by which a call of `with` on the struct knows it. */
	public static final MEMBERWISE = ":memberwise";

	/** Whether `constructor` is a struct's memberwise constructor. */
	public static function isMemberwise(constructor:AstFunction):Bool {
		for (metadata in constructor.metadata)
			if (metadata.name == MEMBERWISE)
				return true;
		return false;
	}

	/**
	 * Adds the missing constructors to `classes` (canonical, qualified names), returning the ones added, each with the class it
	 * replaced its owner with, so the caller can register them wherever it tracks functions. `classes` entries are replaced, never
	 * mutated: they may be shared with cached module contributions.
	 */
	public static function add(classes:Array<AstClass>):Array<{
		owner:String,
		/** The base whose constructor it forwards to, or null for a struct's memberwise constructor. */
		base:Null<String>,
		/** For a memberwise constructor, the structs its owner holds, directly or not, whose layout decided it. */
		held:Array<String>,
		method:AstFunction,
		declaration:AstClass
	}> {
		var indexOf:Map<String, Int> = [];
		for (index in 0...classes.length)
			indexOf.set(classes[index].name, index);
		var added:Array<{
			owner:String,
			base:Null<String>,
			held:Array<String>,
			method:AstFunction,
			declaration:AstClass
		}> = [],
			resolved:Map<String, Bool> = [],
			visiting:Map<String, Bool> = [],
			provided:Map<String, ProvidedConstructor> = [],
			nativeLayout:Map<String, Bool> = [];
		function isNativeLayout(className:String):Bool {
			if (nativeLayout.exists(className))
				return nativeLayout.get(className);
			var index = indexOf.get(className);
			// A cycle adds nothing: a struct cannot hold itself by value.
			nativeLayout.set(className, false);
			var found = false;
			if (index != null) {
				var declaration = classes[index];
				found = declaration.isStruct == true && hasRepr(declaration);
				for (field in declaration.fields)
					if (!found && !field.isStatic && field.type != null
						&& mentionsNativeLayout(field.type, isNativeLayout))
						found = true;
			}
			nativeLayout.set(className, found);
			return found;
		}
		// The program's structs `declaration` holds, directly or through another, whose layout decides its own.
		function heldBy(declaration:AstClass):Array<String> {
			var held:Array<String> = [], walked = [declaration], cursor = 0;
			while (cursor < walked.length) {
				var next = walked[cursor++];
				for (field in next.fields)
					if (!field.isStatic && field.type != null)
						for (name in namedTypes(field.type)) {
							var index = indexOf.get(name);
							if (index != null && name != declaration.name && held.indexOf(name) < 0) {
								held.push(name);
								walked.push(classes[index]);
							}
						}
			}
			return held;
		}
		function provide(className:String):Null<ProvidedConstructor> {
			if (provided.exists(className))
				return provided.get(className);
			var index = indexOf.get(className);
			if (index == null || resolved.exists(className) || visiting.exists(className))
				return null;
			visiting.set(className, true);
			var declaration = classes[index],
				result:Null<ProvidedConstructor> = null;
			if (declaration.isExtern != true) {
				var own = constructorOf(declaration);
				if (own != null)
					result = {arguments: own.arguments, typeParameters: declaration.typeParameters};
				else if (declaration.isStruct == true && declaration.base == null
					&& memberwiseFields(declaration) != null
					&& !hasMetadata(declaration, "annotation") && !isNativeLayout(declaration.name)) {
					var memberwise = memberwise(declaration);
					classes[index] = memberwise.declaration;
					added.push({
						owner: className,
						base: null,
						held: heldBy(declaration),
						method: memberwise.method,
						declaration: memberwise.declaration
					});
					result = {arguments: memberwise.method.arguments, typeParameters: declaration.typeParameters};
				} else {
					var baseName = nominalName(declaration.base),
						base = baseName == null ? null : provide(baseName);
					if (base != null) {
						var method = forwardingConstructor(declaration, base);
						classes[index] = withMethod(declaration, method);
						added.push({
							owner: className,
							base: baseName,
							held: [],
							method: method,
							declaration: classes[index]
						});
						result = {arguments: method.arguments, typeParameters: declaration.typeParameters};
					} else if (hasInstanceInitializers(declaration))
						// Typing supplies a constructor that runs the initializers.
						result = {arguments: [], typeParameters: declaration.typeParameters};
				}
			}
			visiting.remove(className);
			resolved.set(className, true);
			if (result != null)
				provided.set(className, result);
			return result;
		}
		for (declaration in classes.copy())
			provide(declaration.name);
		return added;
	}

	static function hasMetadata(declaration:AstClass, name:String):Bool {
		for (metadata in declaration.metadata)
			if (metadata.name == name)
				return true;
		return false;
	}

	static function hasRepr(declaration:AstClass):Bool {
		for (metadata in declaration.metadata)
			if (metadata.name == "repr" && metadata.arguments.length == 1
				&& metadata.arguments[0].match(StringLiteral("C", _)))
				return true;
		return false;
	}

	/** Whether `type` is or holds a native scalar or a struct `nativeStruct` says is native-layout. */
	static function mentionsNativeLayout(type:AstType, nativeStruct:String->Bool):Bool {
		for (name in namedTypes(type))
			if (compiler.ffi.NativeLayout.scalarTag(name) != null || nativeStruct(name))
				return true;
		return false;
	}

	/** The names `type` mentions. */
	static function namedTypes(type:AstType):Array<String>
		return switch type {
			case NamedType(name): [name];
			case AppliedType(name,
				arguments): [name].concat([for (argument in arguments) for (inner in namedTypes(argument)) inner]);
			case ArrayType(element), NullableType(element): namedTypes(element);
			case MapType(key, value): namedTypes(key).concat(namedTypes(value));
			case AnonymousType(fields): [for (field in fields) for (inner in namedTypes(field.type)) inner];
			default: [];
		};

	static function constructorOf(declaration:AstClass):Null<AstFunction> {
		for (method in declaration.methods)
			if (method.name == "new" && !method.isStatic)
				return method;
		return null;
	}

	public static function hasInstanceInitializers(declaration:AstClass):Bool {
		for (field in declaration.fields)
			if (!field.isStatic && field.initializer != null)
				return true;
		for (method in declaration.methods)
			if (!method.isStatic && method.isDynamic == true)
				return true;
		return false;
	}

	/** A struct's stored instance fields, or null when one has no type annotation, whose type is then its initializer's. */
	static function memberwiseFields(declaration:AstClass):Null<Array<AstField>> {
		var stored:Array<AstField> = [];
		for (field in declaration.fields)
			if (!field.isStatic && hasStorage(field)) {
				if (field.type == null)
					return null;
				stored.push(field);
			}
		return stored;
	}

	static function hasStorage(field:AstField):Bool {
		if (directAccess(field.readAccess) || directAccess(field.writeAccess))
			return true;
		for (metadata in field.metadata)
			if (metadata.name == "isVar")
				return true;
		return false;
	}

	static function directAccess(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
		return switch access {
			case GetAccess, SetAccess, NeverAccess: false;
			default: true;
		};

	/** `new(field:T = initializer, ...) { this.field = field; ... }` for a struct's stored fields, and the struct with it. */
	static function memberwise(declaration:AstClass):{method:AstFunction, declaration:AstClass} {
		var stored = memberwiseFields(declaration);
		if (stored == null)
			throw new compiler.core.InternalError('Struct "${declaration.name}" has no memberwise fields');
		var arguments:Array<AstArgument> = [],
			statements:Array<AstStatement> = [];
		for (field in stored) {
			var type:AstType = field.type == null ? InferredType : field.type;
			arguments.push({
				name: field.name,
				type: type,
				span: field.span,
				defaultValue: field.initializer,
				defaultValueSpan: field.initializer == null
					? null : compiler.syntax.Parser.expressionSpan(field.initializer)
			});
			statements.push(FieldAssignment(Variable("this", field.span), field.name, Variable(field.name, field.span),
				field.span));
		}
		var method:AstFunction = {
			name: "new",
			isStatic: false,
			visibility: AstVisibility.Public,
			metadata: [{name: MEMBERWISE, arguments: [], span: declaration.span}],
			arguments: arguments,
			result: VoidType,
			statements: statements,
			span: declaration.span
		};
		return {
			method: method,
			declaration: {
				name: declaration.name,
				isStruct: declaration.isStruct,
				isExtern: declaration.isExtern,
				isAbstract: declaration.isAbstract,
				typeParameters: declaration.typeParameters,
				typeConstraints: declaration.typeConstraints,
				visibility: declaration.visibility,
				metadata: declaration.metadata,
				base: declaration.base,
				interfaces: declaration.interfaces,
				fields: [
					for (field in declaration.fields)
						stored.indexOf(field) >= 0 && field.initializer != null && !isLiteral(field.initializer)
						? withoutInitializer(field) : field
				],
				methods: declaration.methods.concat([method]),
				span: declaration.span
			}
		};
	}

	/** Whether `expression` is a literal, which a field's descriptor can hold as its default. */
	static function isLiteral(expression:AstExpression):Bool
		return switch expression {
			case IntegerLiteral(_, _), FloatLiteral(_, _), StringLiteral(_, _), BoolLiteral(_, _), NullLiteral(_): true;
			case Negate(IntegerLiteral(_, _), _), Negate(FloatLiteral(_, _), _): true;
			default: false;
		};

	static function withoutInitializer(field:AstField):AstField
		return {
			name: field.name,
			visibility: field.visibility,
			metadata: field.metadata,
			type: field.type,
			initializer: null,
			readAccess: field.readAccess,
			writeAccess: field.writeAccess,
			isStatic: field.isStatic,
			isInline: field.isInline,
			isFinal: field.isFinal,
			span: field.span,
			declarationSpan: field.declarationSpan
		};

	static function nominalName(type:Null<AstType>):Null<String>
		return switch type {
			case NamedType(name), AppliedType(name, _): name;
			default: null;
		};

	/** `new(arguments) { super(arguments); }`, with the base's type parameters replaced by what this class extends it with. */
	static function forwardingConstructor(declaration:AstClass, base:ProvidedConstructor):AstFunction {
		var span = declaration.span, substitutions:Map<String, AstType> = [];
		switch declaration.base {
			case AppliedType(_, typeArguments):
				for (index in 0...base.typeParameters.length)
					if (index < typeArguments.length)
						substitutions.set(base.typeParameters[index], typeArguments[index]);
			default:
		}
		var arguments:Array<AstArgument> = [],
			forwarded:Array<AstExpression> = [];
		for (argument in base.arguments) {
			arguments.push({
				name: argument.name,
				type: substitute(argument.type, substitutions),
				span: span,
				optional: argument.optional,
				defaultValueSpan: argument.defaultValueSpan,
				defaultValue: argument.defaultValue
			});
			forwarded.push(Variable(argument.name, span));
		}
		var statements:Array<AstStatement> = [Expression(Call("super", forwarded, span), span)];
		// Haxe constructs a class without a constructor of its own through its base's, whatever that one's visibility.
		return {
			name: "new",
			isStatic: false,
			visibility: AstVisibility.Public,
			metadata: [],
			arguments: arguments,
			result: VoidType,
			statements: statements,
			span: span
		};
	}

	static function withMethod(declaration:AstClass, method:AstFunction):AstClass
		return {
			name: declaration.name,
			isStruct: declaration.isStruct,
			isExtern: declaration.isExtern,
			isAbstract: declaration.isAbstract,
			typeParameters: declaration.typeParameters,
			typeConstraints: declaration.typeConstraints,
			visibility: declaration.visibility,
			metadata: declaration.metadata,
			base: declaration.base,
			interfaces: declaration.interfaces,
			fields: declaration.fields,
			methods: declaration.methods.concat([method]),
			span: declaration.span
		};

	/** `type` with the type parameters `substitutions` names replaced. */
	public static function substitute(type:AstType, substitutions:Map<String, AstType>):AstType {
		if (substitutions.keys().hasNext() == false)
			return type;
		return switch type {
			case NamedType(name):
				var replacement = substitutions.get(name);
				replacement == null ? type : replacement;
			case AppliedType(name, arguments): AppliedType(name,
				[for (argument in arguments) substitute(argument, substitutions)]);
			case ArrayType(element): ArrayType(substitute(element, substitutions));
			case MapType(key, value): MapType(substitute(key, substitutions), substitute(value, substitutions));
			case NullableType(element): NullableType(substitute(element, substitutions));
			case FunctionType(arguments, result, optional):
				FunctionType([for (argument in arguments) substitute(argument, substitutions)],
					substitute(result, substitutions), optional);
			case AnonymousType(fields):
				AnonymousType([for (field in fields)
					{
						name: field.name,
						type: substitute(field.type, substitutions),
						optional: field.optional,
						isFinal: field.isFinal,
						metadata: field.metadata,
						span: field.span
					}]);
			default: type;
		};
	}
}
