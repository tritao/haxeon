package compiler.semantic;

import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Deterministic spelling for resolved semantic types and callable signatures. */
class SemanticSignature {
	public static function anonymousTypeName(fields:Array<compiler.types.Type.AnonymousField>):String
		return '$' + 'anon:' + anonymousFields(fields);

	/**
	 * A structure that contains itself cannot be spelled out from its fields, since the spelling would never end.
	 * It is named after the typedef that declares it instead.
	 */
	public static function recursiveAnonymousName(declaration:String):String
		return '$' + 'anon:rec:' + declaration;

	public static function isRecursiveAnonymousName(name:String):Bool
		return StringTools.startsWith(name, '$' + 'anon:rec:');

	/**
	 * How many anonymous shapes have been spelled out. Spelling costs time proportional to the shape's size,
	 * so tests use this to check that a shape is spelled once per declaration, not once per mention.
	 */
	public static var anonymousSpellings = 0;

	static function anonymousFields(fields:Array<compiler.types.Type.AnonymousField>):String {
		anonymousSpellings++;
		var ordered = fields.copy();
		ordered.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return '{${[for (field in ordered) (field.optional ? "?" : "") + (field.isFinal ? "final " : "") + field.name + ":" + type(field.type)].join(",")}}';
	}

	public static function type(semanticType:CompilerType):String
		return switch semanticType {
			case TInt: "Int";
			case TInt64: "haxe.Int64";
			case TBool: "Bool";
			case TFloat: "Float";
			case TString: "String";
			case TBytes: "Bytes";
			case THlBytes: "hl.Bytes";
			case TDynamic: "Dynamic";
			case TNativeAbstract(name): 'hl.Abstract<"$name">';
			case TNativeScalar(name): 'native-scalar:$name';
			case TNever: "Never";
			case TRange: "Range";
			case TVoid: "Void";
			case TTypeParameter(owner, name): 'type-parameter:$owner:$name';
			case TAbstract(name, arguments, _): 'abstract:$name<${[for (argument in arguments) type(argument)].join(",")}>';
			case TInstance(kind, name, arguments):
				var prefix = switch kind {
					case NominalKind.Class: "class";
					case NominalKind.Interface: "interface";
					case NominalKind.Enum: "enum";
					case NominalKind.NativeValue: "native-value";
					default: throw 'Unknown nominal kind $kind';
				};
				'$prefix:$name<${[for (argument in arguments) type(argument)].join(",")}>';
			case TNull: "null";
			case TNullable(element): 'Null<${type(element)}>';
			case TArray(element): 'Array<${type(element)}>';
			case TIterator(element): 'Iterator<${type(element)}>';
			case TMap(key, value): 'Map<${type(key)},${type(value)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) type(argument)].join(",")})->${type(result)}';
			case TAnonymous(name, _): name;
		};

	public static function parsedFunction(fn:AstFunction, aliases:Array<AstTypeAlias>):String {
		var definitions:Map<String, AstType> = [for (alias in aliases) alias.name => alias.type],
			typeParameters = fn.typeParameters;
		return fn.name
			+ (typeParameters == null
				|| typeParameters.length == 0 ? "" : '<${[for (parameter in typeParameters) parameter + parsedConstraint(fn, parameter, definitions)].join(",")}>')
			+ "(" // Whether an argument may be omitted is part of the signature: callers are checked against the arity range.
			+ [for (argument in fn.arguments) parsedArgument(argument, definitions)].join(",") + ")->" + parsedType(fn.result, definitions, []);
	}

	/**
	 * An argument as callers see it: its type, whether it may be omitted, and what it defaults to. A caller that
	 * omits an argument is lowered with the default at the call site, so a changed default changes every such call
	 * although each still type-checks; the default's source text stands for its value.
	 */
	static function parsedArgument(argument:AstArgument, definitions:Map<String, AstType>):String {
		var type = parsedType(argument.type, definitions, []);
		if (argument.defaultValue == null)
			return (argument.optional == true ? "?" : "") + type;
		var span = argument.span;
		return "?" + type + "=" + span.file.slice(span.start, span.end);
	}

	static function parsedConstraint(fn:AstFunction, parameter:String, definitions:Map<String, AstType>):String {
		var constraints = fn.typeConstraints;
		if (constraints != null)
			for (constraint in constraints)
				if (constraint.parameter == parameter)
					return ":" + parsedType(constraint.type, definitions, []);
		return "";
	}

	public static function parsed(type:AstType, aliases:Array<AstTypeAlias>):String
		return parsedType(type, [for (alias in aliases) alias.name => alias.type], []);

	public static function parsedParameters(parameters:Array<String>, constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>,
			aliases:Array<AstTypeAlias>):String {
		var definitions:Map<String, AstType> = [for (alias in aliases) alias.name => alias.type];
		return [
			for (parameter in parameters)
				parameter + parsedParameterConstraint(parameter, constraints, definitions)
		].join(",");
	}

	static function parsedParameterConstraint(parameter:String, constraints:Null<Array<compiler.syntax.Ast.AstTypeConstraint>>,
			definitions:Map<String, AstType>):String {
		if (constraints == null)
			return "";
		var bounds = [
			for (constraint in constraints)
				if (constraint.parameter == parameter) parsedType(constraint.type, definitions, [])
		];
		return bounds.length == 0 ? "" : bounds.length == 1 ? ":" + bounds[0] : ":(" + bounds.join(",") + ")";
	}

	static function parsedType(type:AstType, aliases:Map<String, AstType>, resolving:Map<String, Bool>):String
		return switch type {
			case ErrorType(_): "_";
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case InferredType: "_";
			case NativeAbstractType(declaration, tag): '$declaration<"$tag">';
			case NamedType(name):
				if (!aliases.exists(name) || resolving.exists(name)) name; else {
					var alias = aliases.get(name);
					resolving.set(name, true);
					var result = parsedType(alias, aliases, resolving);
					resolving.remove(name);
					result;
				}
			case AppliedType(name, arguments): '$name<${[for (argument in arguments) parsedType(argument, aliases, resolving)].join(",")}>';
			case ArrayType(element): 'Array<${parsedType(element, aliases, resolving)}>';
			case MapType(key, value): 'Map<${parsedType(key, aliases, resolving)},${parsedType(value, aliases, resolving)}>';
			case NullableType(element): 'Null<${parsedType(element, aliases, resolving)}>';
			case FunctionType(arguments, result):
				'(${[for (argument in arguments) parsedType(argument, aliases, resolving)].join(",")})->${parsedType(result, aliases, resolving)}';
			case AnonymousType(fields):
				var ordered = fields.copy();
				ordered.sort(function(left, right) return Reflect.compare(left.name, right.name));
				'{${[for (field in ordered) (field.optional ? "?" : "") + field.name + ":" + parsedType(field.type, aliases, resolving)].join(",")}}';
		};
}
