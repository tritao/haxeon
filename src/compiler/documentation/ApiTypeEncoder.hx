package compiler.documentation;

import compiler.documentation.ApiModel.ApiType;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;

/** Serializes semantic type structure while closing recursive anonymous shapes locally. */
class ApiTypeEncoder {
	public static function encode(type:CompilerType):ApiType
		return encodeWithin(type, []);

	static function encodeWithin(type:CompilerType, active:Array<Array<AnonymousField>>):ApiType
		return switch type {
			case TInt: builtin("Int");
			case TInt64: builtin("haxe.Int64");
			case TBool: builtin("Bool");
			case TFloat: builtin("Float");
			case TString: builtin("String");
			case TBytes: builtin("Bytes");
			case THlBytes: builtin("hl.Bytes");
			case TDynamic: builtin("Dynamic");
			case TNever: builtin("Never");
			case TRange: builtin("Range");
			case TVoid: builtin("Void");
			case TNull: builtin("null");
			case TNativeAbstract(name): {kind: "nativeAbstract", name: name};
			case TNativeScalar(name): {kind: "nativeScalar", name: name};
			case TTypeParameter(owner, name): {kind: "parameter", owner: owner, name: name};
			case TAbstract(path, arguments, _) | TInstance(_, path, arguments):
				{kind: "named", path: path, arguments: [for (argument in arguments) encodeWithin(argument, active)]};
			case TNullable(element): builtin("Null", [encodeWithin(element, active)]);
			case TArray(element): builtin("Array", [encodeWithin(element, active)]);
			case TIterator(element): builtin("Iterator", [encodeWithin(element, active)]);
			case TMap(key, value): builtin("Map", [encodeWithin(key, active), encodeWithin(value, active)]);
			case TKeyPath(root, value, writable):
				builtin(writable ? "WritableKeyPath" : "KeyPath", [
					encodeWithin(root, active),
					encodeWithin(value, active)
				]);
			case TFunction(arguments, result, optional):
				{kind: "function",
					// An optional argument's checked type is `Null<T>`: the model gives `T`, as declared, beside its flag.
					arguments: [for (index in 0...arguments.length) encodeWithin(switch arguments[index] {
						case TNullable(element) if (index < optional.length && optional[index]): element;
						case argument: argument;
					}, active)],
						optional: [for (index in 0...arguments.length) index < optional.length && optional[index]],
						result: encodeWithin(result, active)};
			case TAnonymous(_, fields): anonymous(fields, active);
			case TMonomorph(cell): cell.bound == null ? builtin("Dynamic") : encodeWithin(cell.bound, active);
		};

	static function builtin(path:String, ?arguments:Array<ApiType>):ApiType
		return {kind: "builtin", path: path, arguments: arguments ?? []};

	static function anonymous(fields:Array<AnonymousField>, active:Array<Array<AnonymousField>>):ApiType {
		var seen = active.indexOf(fields);
		if (seen >= 0)
			return {kind: "anonymousRef", id: seen};
		var ordered = fields.copy(), id = active.length;
		ordered.sort((left, right) -> Reflect.compare(left.name, right.name));
		active.push(fields);
		var result:ApiType = {kind: "anonymous",
			id: id,
			fields: [for (field in ordered) {
				name:field.name,
					type:encodeWithin(field.type, active),
					optional:field.optional,
					isFinal:field.isFinal
			}]};
		active.pop();
		return result;
	}
}
