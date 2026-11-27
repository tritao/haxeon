package compiler.ffi;

import compiler.core.InternalError;
import compiler.core.Source.SourceSpan;
import compiler.ffi.HxiAbi.HxiTypeLayout;
import compiler.ffi.HxiModel.HxiType;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedNativeLayout;

/** C record layout of source-declared native values, by the same HxiAbi rules that lay out HXI structs. */
class NativeLayout {
	/** The tag of the native scalar type named `name` (`UInt8` is "u8"), or null when it names none. */
	public static function scalarTag(name:String):Null<String>
		return switch name {
			case "Int8": "i8";
			case "UInt8": "u8";
			case "Int16": "i16";
			case "UInt16": "u16";
			case "Int32": "i32";
			case "UInt32": "u32";
			case "UInt64": "u64";
			case "Float32": "f32";
			case "Float64": "f64";
			case "CChar": "c_char";
			case "CSignedChar": "c_schar";
			case "CUChar": "c_uchar";
			case "CBool": "c_bool";
			case "CShort": "c_short";
			case "CUShort": "c_ushort";
			case "CInt": "c_int";
			case "CUInt": "c_uint";
			case "CLong": "c_long";
			case "CULong": "c_ulong";
			case "CLongLong": "c_long_long";
			case "CULongLong": "c_ulong_long";
			case "CSize": "c_size";
			case "CWChar": "c_wchar";
			default: null;
		};

	public static function isNativeValue(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.NativeValue, _, _): true;
			case _: false;
		};

	public static function containsNativeLayoutType(type:CompilerType):Bool
		return containsNativeLayoutWithin(type, null);

	/**
	 * Whether a type still needs native-memory-only handling to be represented
	 * as an ordinary Haxe runtime value. UInt32 is the one fixed-width scalar
	 * with a lossless i32 carrier on both supported runtime backends. Its
	 * supported containers are limited to Array. This is a bit-preserving
	 * storage and call boundary only; it does not enable unsigned arithmetic,
	 * nullable UInt32, map values, enum payloads, or foreign by-value calls.
	 */
	public static function containsUnsupportedRuntimeValueType(type:CompilerType):Bool
		return containsUnsupportedRuntimeValueWithin(type, null);

	static function containsUnsupportedRuntimeValueWithin(type:CompilerType,
			explored:Null<Array<Array<compiler.types.Type.AnonymousField>>>):Bool
		return switch type {
			case TNativeScalar("u32"): false;
			case TNullable(TNativeScalar("u32")): true;
			case TNullable(TArray(element)): containsUnsupportedRuntimeValueWithin(element, explored);
			case TNativeScalar(_) | TInstance(NominalKind.NativeValue, _, _): true;
			case TAbstract(_, _, representation), TArray(representation):
				containsUnsupportedRuntimeValueWithin(representation, explored);
			case TNullable(_) | TIterator(_) | TMap(_, _) | TFunction(_, _, _): containsNativeLayoutType(type);
			case TAnonymous(_, fields):
				var walked = explored == null ? [] : explored, found = false;
				if (walked.indexOf(fields) < 0) {
					walked.push(fields);
					for (field in fields)
						if (containsUnsupportedRuntimeValueWithin(field.type, walked))
							found = true;
				}
				found;
			case _: false;
		};

	/** `explored` holds the anonymous structures already walked: one can contain itself, and a repeat adds nothing. */
	static function containsNativeLayoutWithin(type:CompilerType,
			explored:Null<Array<Array<compiler.types.Type.AnonymousField>>>):Bool
		return switch type {
			case TNativeScalar(_) | TInstance(NominalKind.NativeValue, _, _): true;
			case TAbstract(_, _, representation), TNullable(representation), TArray(representation),
				TIterator(representation):
				containsNativeLayoutWithin(representation, explored);
			case TMap(key, value): containsNativeLayoutWithin(key, explored)
				|| containsNativeLayoutWithin(value, explored);
			case TFunction(arguments, result, _):
				var found = containsNativeLayoutWithin(result, explored);
				for (argument in arguments)
					if (containsNativeLayoutWithin(argument, explored))
						found = true;
				found;
			case TAnonymous(_, fields):
				var walked = explored == null ? [] : explored, found = false;
				if (walked.indexOf(fields) < 0) {
					walked.push(fields);
					for (field in fields)
						if (containsNativeLayoutWithin(field.type, walked))
							found = true;
				}
				found;
			case _: false;
		};

	public static function fieldType(type:CompilerType):HxiType
		return switch type {
			case TInt: Primitive("i32");
			case TInt64: Primitive("i64");
			case TBool: Primitive("c_bool");
			case TFloat: Primitive("f64");
			case TNativeScalar(name): Primitive(name);
			case TAbstract(declaration, _,
				_) if (StringTools.endsWith(Std.string(declaration), "RawPtr")): Pointer(Primitive("void"));
			case TAbstract(_, _, representation): fieldType(representation);
			case TInstance(NominalKind.NativeValue, name, _): Named(name);
			case TInstance(NominalKind.Class, name, []): Named(name);
			case _: throw new InternalError('Type $type is not an unmanaged native field type');
		};

	/** Calculate a source-declared record by aligning each field as the ABI does; `nested` lays out the records it nests. */
	public static function record(target:String, name:String, fields:Array<{
		name:String,
		type:CompilerType,
		span:SourceSpan
	}>,
			nested:Map<String, HxiTypeLayout>, span:SourceSpan):TypedNativeLayout {
		var abi = HxiAbi.forTarget(target, null, nested), types:Array<HxiType> = [], layouts:Array<HxiTypeLayout> = [];
		for (field in fields) {
			var hxiType = fieldType(field.type), layout = abi.layout(hxiType);
			if (layout == null || layout.size <= 0 || layout.align <= 0)
				throw new InternalError('Field "${field.name}" in native record "$name" has no fixed C layout');
			types.push(hxiType);
			layouts.push(layout);
		}
		var record = abi.recordLayout(types);
		return {
			target: target,
			size: fields.length == 0 ? 1 : record.size,
			alignment: record.align,
			fields: [for (index in 0...fields.length) {
				name: fields[index].name,
				offset: record.offsets[index],
				size: layouts[index].size,
				alignment: layouts[index].align
			}]
		};
	}
}
