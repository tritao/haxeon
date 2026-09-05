package compiler.types;

import compiler.Ast.AstFunction;
import compiler.Ast.AstType;
import compiler.Ast.AstTypeAlias;
import compiler.types.Type.CompilerType;

/** Deterministic spelling for resolved semantic types and callable signatures. */
class SemanticSignature {
	public static function type(semanticType:CompilerType):String
		return switch semanticType {
			case TInt: "Int";
			case TBool: "Bool";
			case TFloat: "Float";
			case TString: "String";
			case TDynamic: "Dynamic";
			case TVoid: "Void";
			case TClass(name): 'class:$name';
			case TInterface(name): 'interface:$name';
			case TEnum(name): 'enum:$name';
			case TNull: "null";
			case TNullable(element): 'Null<${type(element)}>';
			case TArray(element): 'Array<${type(element)}>';
			case TMap(key, value): 'Map<${type(key)},${type(value)}>';
			case TFunction(arguments, result): '(${[for (argument in arguments) type(argument)].join(",")})->${type(result)}';
			case TAnonymous(_, fields):
				'{${[for (field in fields) (field.optional ? "?" : "") + field.name + ":" + type(field.type)].join(",")}}';
		};

	public static function parsedFunction(fn:AstFunction, aliases:Array<AstTypeAlias>):String {
		var definitions = [for (alias in aliases) alias.name => alias.type];
		return fn.name
			+ (fn.typeParameters == null || fn.typeParameters.length == 0 ? "" : '<${fn.typeParameters.join(",")}>')
			+ "("
			+ [for (argument in fn.arguments) parsedType(argument.type, definitions, [])].join(",") + ")->" + parsedType(fn.result, definitions, []);
	}

	public static function parsed(type:AstType, aliases:Array<AstTypeAlias>):String
		return parsedType(type, [for (alias in aliases) alias.name => alias.type], []);

	static function parsedType(type:AstType, aliases:Map<String, AstType>, resolving:Map<String, Bool>):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case NamedType(name):
				var alias = aliases.get(name);
				if (alias == null || resolving.exists(name)) name; else {
					resolving.set(name, true);
					var result = parsedType(alias, aliases, resolving);
					resolving.remove(name);
					result;
				}
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
