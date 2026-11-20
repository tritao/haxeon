package compiler.runtime;

import compiler.core.InternalError;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrType;

/** Source signature and HashLink binding for one immutable host native. */
typedef NativeDefinition = {
	final name:String;
	final library:String;
	final symbol:String;
	final arguments:Array<CompilerType>;
	final result:CompilerType;
	@:optional final generatedFunctionDependencies:Null<Array<String>>;
}

/** Owns immutable compiler native definitions and their derived views. */
class NativeRegistry {
	final definitions:Map<String, NativeDefinition> = [];

	/** The first part of every dotted native name (`hasChild`). */
	final parents:Map<String, Bool> = [];

	public function new(?configuration:Array<NativeDefinition>) {
		if (configuration != null)
			for (native in configuration)
				registerNative(native.name, native.library, native.symbol, native.arguments, native.result,
					native.generatedFunctionDependencies);
	}

	public function registerNative(name:String, library:String, symbol:String, arguments:Array<CompilerType>,
			result:CompilerType,
			?generatedFunctionDependencies:Array<String>):Void {
		if (isReserved(name))
			throw new InternalError('Native "$name" is reserved by the compiler runtime ABI');
		if (definitions.exists(name))
			throw new InternalError('Native "$name" is already registered');
		var dot = name.indexOf(".");
		if (dot > 0)
			parents.set(name.substring(0, dot), true);
		definitions.set(name, {
			name: name,
			library: library,
			symbol: symbol,
			arguments: arguments.copy(),
			result: result,
			generatedFunctionDependencies: generatedFunctionDependencies == null
				? null : generatedFunctionDependencies.copy()
		});
	}

	public function configuration():Array<NativeDefinition> {
		var names = sortedNames();
		return [for (name in names) copy(requireDefinition(name))];
	}

	public function signatures():Map<String, {arguments:Array<CompilerType>, result:CompilerType}> {
		var result:Map<String, {arguments:Array<CompilerType>, result:CompilerType}> = [];
		for (name in sortedNames()) {
			var native = requireDefinition(name);
			result.set(name, {arguments: native.arguments.copy(), result: native.result});
		}
		return result;
	}

	/** Whether a native is named `prefix.something`. */
	public function hasChild(prefix:String):Bool
		return parents.exists(prefix);

	public function irNatives():Array<IrNative>
		return [for (name in sortedNames()) {
			var native = requireDefinition(name);
			{
				name:native.name,
					library:native.library,
					symbol:native.symbol,
					arguments:[for (argument in native.arguments) irType(argument)],
					result:irType(native.result),
					generatedFunctionDependencies:native.generatedFunctionDependencies == null
					? null : native.generatedFunctionDependencies.copy()
			};
		}];

	function sortedNames():Array<String> {
		var names = [for (name in definitions.keys()) name];
		names.sort(Reflect.compare);
		return names;
	}

	function requireDefinition(name:String):NativeDefinition {
		if (!definitions.exists(name))
			throw new InternalError('Missing native definition "$name"');
		return definitions.get(name);
	}

	static function copy(native:NativeDefinition):NativeDefinition
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			arguments: native.arguments.copy(),
			result: native.result,
			generatedFunctionDependencies: native.generatedFunctionDependencies == null
				? null : native.generatedFunctionDependencies.copy()
		};

	static function irType(type:CompilerType):IrType
		return switch type {
			case TMonomorph(cell): throw new InternalError('Internal error: the type of ${cell.origin} reached a native signature unresolved');
			case TAbstract(declaration, _, _) if (StringTools.endsWith(Std.string(declaration), "RawPtr")): RawPtr;
			case TAbstract(_, _, representation): irType(representation);
			case TInt: I32;
			case TInt64: I64;
			case TBool: Bool;
			case TFloat: F64;
			case TNativeScalar("f32"): F32;
			case TNativeScalar("f64"): F64;
			case TNativeScalar("i64" | "u64" | "c_long" | "c_ulong" | "c_long_long" | "c_ulong_long" | "c_size"): I64;
			case TNativeScalar("c_bool"): Bool;
			case TNativeScalar(_): I32;
			case TString: IrType.Bytes;
			case TBytes: ManagedBytes;
			case THlBytes: RawPtr;
			case TDynamic: Dyn;
			case TNativeAbstract(name): Abstract(name);
			case TNever: throw new InternalError("Never is not a runtime ABI type");
			case TTypeParameter(owner,
				name): throw new InternalError('Type parameter "$owner.$name" is not a runtime ABI type');
			case TRange: throw new InternalError("Range is not a runtime ABI type");
			case TVoid: Void;
			case TInstance(kind, name, _):
				switch kind {
					case NominalKind.Class: Obj(name);
					case NominalKind.Interface: Virtual(name);
					case NominalKind.Enum: Enum(name);
					case NominalKind.NativeValue: throw new InternalError('Native value record "$name" cannot be lowered as a managed value');
					default: throw new InternalError('Unknown nominal kind $kind');
				}
			case TMap(_, _): Abstract("map_string_i32");
			case TKeyPath(root, value, _): Obj(compiler.types.KeyPathType.descriptorName(root, value));
			case TNull: Void;
			case TNullable(element): irType(element);
			case TArray(element): Array(irType(element));
			case TIterator(_): Abstract("realtime_iterator");
			case TFunction(arguments, result, _): Function([for (argument in arguments) irType(argument)],
				irType(result));
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
