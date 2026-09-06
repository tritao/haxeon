package compiler.runtime;

import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;

/** Source signature and HashLink binding for one immutable host native. */
typedef NativeDefinition = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<CompilerType>;
	final result:CompilerType;
}

/** Owns immutable compiler native definitions and their derived views. */
class NativeRegistry {
	final definitions:Map<String, NativeDefinition> = [];

	public function new(?configuration:Array<NativeDefinition>) {
		if (configuration != null)
			for (native in configuration)
				registerNative(native.name, native.library, native.symbol, native.arguments, native.result);
	}

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>, result:CompilerType):Void {
		if (isReserved(name))
			throw 'Native "$name" is reserved by the compiler runtime ABI';
		if (definitions.exists(name))
			throw 'Native "$name" is already registered';
		definitions.set(name, {
			name: name,
			library: library,
			symbol: symbol,
			arguments: arguments.copy(),
			result: result
		});
	}

	public function configuration():Array<NativeDefinition> {
		var names = sortedNames();
		return [for (name in names) copy(definitions.get(name))];
	}

	public function signatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}> {
		var result:Map<String, {arguments:Array<CompilerType>, result:CompilerType}> = [];
		for (name in sortedNames()) {
			var native = definitions.get(name);
			result.set(name, {arguments: native.arguments.copy(), result: native.result});
		}
		return result;
	}

	public function hasChild(prefix:String):Bool {
		for (name in definitions.keys())
			if (name != prefix && name.indexOf(".") > 0 && name.substring(0, name.indexOf(".")) == prefix)
				return true;
		return false;
	}

	public function irNatives():Array<IrNative>
		return [
			for (name in sortedNames()) {
				var native = definitions.get(name);
				{
					name: native.name,
					library: native.library,
					symbol: native.symbol,
					arguments: [for (argument in native.arguments) irType(argument)],
					result: irType(native.result)
				};
			}
		];

	function sortedNames():Array<String> {
		var names = [for (name in definitions.keys()) name];
		names.sort(Reflect.compare);
		return names;
	}

	static function copy(native:NativeDefinition):NativeDefinition
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			arguments: native.arguments.copy(),
			result: native.result
		};

	static function irType(type:CompilerType):IrType
		return switch type {
			case TAbstract(_, _, representation): irType(representation);
			case TInt: I32;
			case TBool: Bool;
			case TFloat: F64;
			case TString: IrType.Bytes;
			case TBytes: Abstract("realtime_bytes");
			case THlBytes: IrType.Bytes;
			case TDynamic: Dyn;
			case TNativeAbstract(name): Abstract(name);
			case TNever: throw "Never is not a runtime ABI type";
			case TTypeParameter(owner, name): throw 'Type parameter "$owner.$name" is not a runtime ABI type';
			case TRange: throw "Range is not a runtime ABI type";
			case TVoid: Void;
			case TInstance(Class, name, _): Obj(name);
			case TMap(_, _): Abstract("map_string_i32");
			case TInstance(Interface, name, _): Virtual(name);
			case TInstance(Enum, name, _): Enum(name);
			case TNull: Void;
			case TNullable(element): irType(element);
			case TArray(element): Array(irType(element));
			case TFunction(arguments, result): Function([for (argument in arguments) irType(argument)], irType(result));
			case TAnonymous(name, _): Obj(name);
		};

	static function isReserved(name:String):Bool
		return name == "__exit"
			|| StringTools.startsWith(name, "__array_")
			|| StringTools.startsWith(name, "__map_")
			|| name == "__string_concat"
			|| name == "__string_length"
			|| name == "__string_equal"
			|| name == "__string_index_of"
			|| name == "__string_substring";
}
