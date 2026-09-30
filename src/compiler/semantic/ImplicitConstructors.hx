package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;

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
 */
class ImplicitConstructors {
	/**
	 * Adds the missing constructors to `classes` (canonical, qualified names), returning the ones added so the caller can
	 * register them wherever it tracks functions. `classes` entries are replaced, never mutated: they may be shared with
	 * cached module contributions.
	 */
	public static function add(classes:Array<AstClass>):Array<{owner:String, base:String, method:AstFunction}> {
		var indexOf:Map<String, Int> = [];
		for (index in 0...classes.length)
			indexOf.set(classes[index].name, index);
		var added:Array<{owner:String, base:String, method:AstFunction}> = [],
			resolved:Map<String, Bool> = [],
			visiting:Map<String, Bool> = [],
			provided:Map<String, ProvidedConstructor> = [];
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
				else {
					var baseName = nominalName(declaration.base),
						base = baseName == null ? null : provide(baseName);
					if (base != null) {
						var method = forwardingConstructor(declaration, base);
						classes[index] = withMethod(declaration, method);
						added.push({owner: className, base: baseName, method: method});
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

	static function constructorOf(declaration:AstClass):Null<AstFunction> {
		for (method in declaration.methods)
			if (method.name == "new" && !method.isStatic)
				return method;
		return null;
	}

	static function hasInstanceInitializers(declaration:AstClass):Bool {
		for (field in declaration.fields)
			if (!field.isStatic && field.initializer != null)
				return true;
		return false;
	}

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
				defaultValue: argument.defaultValue
			});
			forwarded.push(Variable(argument.name, span));
		}
		var statements:Array<AstStatement> = [Expression(Call("super", forwarded, span), span)];
		return {
			name: "new",
			isStatic: false,
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
			isExtern: declaration.isExtern,
			typeParameters: declaration.typeParameters,
			typeConstraints: declaration.typeConstraints,
			isPrivate: declaration.isPrivate,
			metadata: declaration.metadata,
			base: declaration.base,
			interfaces: declaration.interfaces,
			fields: declaration.fields,
			methods: declaration.methods.concat([method]),
			span: declaration.span
		};

	static function substitute(type:AstType, substitutions:Map<String, AstType>):AstType {
		if (substitutions.keys().hasNext() == false)
			return type;
		return switch type {
			case NamedType(name):
				var replacement = substitutions.get(name);
				replacement == null ? type : replacement;
			case AppliedType(name, arguments): AppliedType(name, [for (argument in arguments) substitute(argument, substitutions)]);
			case ArrayType(element): ArrayType(substitute(element, substitutions));
			case MapType(key, value): MapType(substitute(key, substitutions), substitute(value, substitutions));
			case NullableType(element): NullableType(substitute(element, substitutions));
			case FunctionType(arguments, result):
				FunctionType([for (argument in arguments) substitute(argument, substitutions)], substitute(result, substitutions));
			case AnonymousType(fields):
				AnonymousType([
					for (field in fields)
						{
							name: field.name,
							type: substitute(field.type, substitutions),
							optional: field.optional,
							isFinal: field.isFinal,
							metadata: field.metadata,
							span: field.span
						}
				]);
			default: type;
		};
	}
}
