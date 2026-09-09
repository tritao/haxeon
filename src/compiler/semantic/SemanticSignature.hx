package compiler.semantic;

import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeAlias;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** Deterministic spelling for resolved semantic types and callable signatures. */
class SemanticSignature {
	public static function anonymousTypeName(fields:Array<compiler.types.Type.AnonymousField>):String
		return '$' + 'anon:' + anonymousFields(fields);

	static function anonymousFields(fields:Array<compiler.types.Type.AnonymousField>):String {
		var ordered = fields.copy();
		ordered.sort(function(left, right) return Reflect.compare(left.name, right.name));
		return '{${[for (field in ordered) (field.optional ? "?" : "") + field.name + ":" + type(field.type)].join(",")}}';
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
					default: throw 'Unknown nominal kind $kind';
				};
				'$prefix:$name<${[for (argument in arguments) type(argument)].join(",")}>';
			case TNull: "null";
			case TNullable(element): 'Null<${type(element)}>';
			case TArray(element): 'Array<${type(element)}>';
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
			+ "("
			+ [for (argument in fn.arguments) parsedType(argument.type, definitions, [])].join(",") + ")->" + parsedType(fn.result, definitions, []);
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
