package compiler.documentation;

import compiler.documentation.ApiModel.ApiArgument;
import compiler.documentation.ApiModel.ApiDeclaration;
import compiler.documentation.ApiModel.ApiMember;
import compiler.documentation.ApiModel.ApiType;
import compiler.documentation.ApiModel.ApiTypeParameter;

/**
 * The API model as Haxe declarations, which the editor shows on hover and in signature help. The website renders the same
 * model with the same rules as HTML (site/api.mjs): docs/design/API_MODEL.md, "Rendering".
 */
class ApiText {
	/** A type as its source writes it: short names, typedefs by name, `?` for an optional function argument. */
	public static function type(value:ApiType):String
		return switch value.kind {
			case "named" | "builtin":
				var arguments = value.arguments ?? [];
				shortName(value.path ?? "") + (arguments.length == 0
					? "" : "<" + [for (argument in arguments) type(argument)].join(", ") + ">");
			case "parameter":
				value.name ?? "";
			case "function":
				var arguments = value.arguments ?? [], optional = value.optional ?? [], result = value.result;
				"(" + [for (index in 0...arguments.length)(optional[index] ? "?" : "")
					+ type(arguments[index])].join(", ") + ") -> "
					+ (result == null ? "Void" : type(result));
			case "anonymous":
				"{ " + [for (field in value.fields ?? [])(field.optional ? "?" : "") + (field.isFinal ? "final " : "")
					+ field.name + ":"
					+ type(field.type)].join(", ") + " }";
			case "anonymousRef":
				"…";
			case _:
				value.name ?? "";
		};

	/** One argument: `?name:T` when it may be left out, `name:T = value` when it has a default. */
	public static function argument(value:ApiArgument):String
		return (value.optional && value.defaultValue == null ? "?" : "") + (value.name ?? "_") + ":" + type(value.type)
			+ (value.defaultValue == null ? "" : " = " + value.defaultValue);

	/** A member as Haxe declares it. */
	public static function member(value:ApiMember):String {
		var statically = value.isStatic && value.kind != "enumConstructor" && value.kind != "enumValue"
			&& value.kind != "function" ? "static " : "";
		inline function arguments():String
			return [for (entry in value.arguments ?? []) argument(entry)].join(", ");
		inline function result():String
			return value.result == null ? "Void" : type(value.result);
		return switch value.kind {
			case "field":
				statically + (value.isFinal == true ? "final " : "var ") + value.name + ":" + optionalType(value.type);
			case "property":
				statically + 'var ${value.name}(${value.get}, ${value.set}):' + optionalType(value.type);
			case "enumValue":
				value.name;
			case "enumConstructor":
				(value.arguments ?? []).length == 0 ? value.name : value.name + "(" + arguments() + ")";
			case "constructor":
				"new(" + arguments() + ")";
			case "operator":
				'@:op(${value.operatorText}) (' + arguments() + "):" + result();
			case "conversion":
				'@:${value.conversion} (' + arguments() + "):" + result();
			case _:
				statically + "function " + value.name + typeParameters(value.typeParameters ?? []) + "(" + arguments()
					+ "):"
					+ result();
		};
	}

	/** A type's declaration line: its kind, name, type parameters, and what it extends, implements or stands for. */
	public static function declaration(value:ApiDeclaration):String {
		var name = shortName(value.path) + typeParameters(value.typeParameters);
		inline function list(word:String, types:Array<ApiType>):String
			return types.length == 0 ? "" : ' $word ' + [for (entry in types) type(entry)].join(", ");
		var underlying = value.underlying == null ? "" : type(value.underlying);
		return switch value.kind {
			case "typedef": 'typedef $name = $underlying';
			case "abstract": (value.isExtern ? "extern " : "") + 'abstract $name($underlying)' + list("from",
				value.from) + list("to", value.to);
			case "interface": 'interface $name' + list("extends", value.supertypes);
			case "enum": 'enum $name' + list("implements", value.interfaces);
			case "extern": 'extern class $name' + list("extends", value.supertypes) + list("implements",
				value.interfaces);
			case _: 'class $name' + list("extends", value.supertypes) + list("implements", value.interfaces);
		};
	}

	static function typeParameters(parameters:Array<ApiTypeParameter>):String
		return parameters.length == 0 ? "" : "<" + [for (parameter in parameters) parameter.name
			+ (parameter.constraints.length == 0
			? "" : ":" + [for (constraint in parameter.constraints) type(constraint)].join(" & "))].join(", ")
			+ ">";

	static function optionalType(value:Null<ApiType>):String
		return value == null ? "Dynamic" : type(value);

	static function shortName(path:String):String
		return path.substr(path.lastIndexOf(".") + 1);
}
