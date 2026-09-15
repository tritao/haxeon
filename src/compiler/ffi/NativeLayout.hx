package compiler.ffi;

import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstMetadata;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiAbi.HxiAbiValue;
import compiler.ffi.HxiAbi.HxiIntegerSign;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedNativeLayout;
import compiler.types.TypedAst.TypedNativeFieldLayout;

/**
 * C record layout shared by source-declared native values and HXI imports.
 * HXI supplies Clang's offsets and total size; source declarations use the
 * same HxiAbi field-size/alignment rules to calculate those facts.
 */
class NativeLayout {
	/** Read the optional inline-array length annotation from a native field. */
	public static function fixedArrayLength(metadata:Array<AstMetadata>):Null<Int> {
		var result:Null<Int> = null;
		for (entry in metadata)
			if (entry.name == "array") {
				if (result != null)
					throw "Duplicate @:array metadata";
				if (entry.arguments.length != 1)
					throw "@:array requires exactly one positive integer argument";
				switch entry.arguments[0] {
					case IntegerLiteral(value, _) if (value > 0):
						result = value;
					case _:
						throw "@:array requires exactly one positive integer argument";
				}
			}
		return result;
	}

	/** Native memory access width and signedness used by RawPtr load/store lowering. */
	public static function memoryAccess(type:CompilerType, target:String):{size:Int, signed:Bool} {
		var hxiType = fieldType(type),
			abi = HxiAbi.forTarget(target),
			layout = abi.layout(hxiType);
		if (layout == null)
			throw 'Type "$type" has no fixed native memory layout for "$target"';
		var signed = switch abi.classify(hxiType) {
			case IntegerValue(_, HxiIntegerSign.Signed) | EnumerationValue(_, _, HxiIntegerSign.Signed): true;
			case _: false;
		};
		return {size: layout.size, signed: signed};
	}

	public static function isNativeValue(type:CompilerType):Bool
		return switch type {
			case TInstance(NominalKind.NativeValue, _, _): true;
			case _: false;
		};

	public static function containsNativeLayoutType(type:CompilerType):Bool
		return switch type {
			case TNativeScalar(_) | TInstance(NominalKind.NativeValue, _, _): true;
			case TAbstract(_, _, representation), TNullable(representation), TArray(representation), TIterator(representation):
				containsNativeLayoutType(representation);
			case TMap(key, value): containsNativeLayoutType(key) || containsNativeLayoutType(value);
			case TFunction(arguments, result):
				var found = containsNativeLayoutType(result);
				for (argument in arguments)
					if (containsNativeLayoutType(argument))
						found = true;
				found;
			case TAnonymous(_, fields):
				var found = false;
				for (field in fields)
					if (containsNativeLayoutType(field.type))
						found = true;
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
			case TAbstract(declaration, _, _) if (StringTools.endsWith(Std.string(declaration), "RawPtr")): Pointer(Primitive("void"));
			case TAbstract(_, _, representation): fieldType(representation);
			case TInstance(NominalKind.NativeValue, name, _): Named(name);
			case _: throw 'Type $type is not an unmanaged native field type';
		};

	public static function nestedDeclaration(name:String, layout:TypedNativeLayout, span:SourceSpan):HxiDeclaration
		return Structure(name, layout.size, layout.alignment, [], span);

	/** Calculate a source-declared record or union using the same ABI facts as HXI. */
	public static function record(target:String, name:String, fields:Array<{
		name:String,
		type:CompilerType,
		span:SourceSpan,
		arrayLength:Null<Int>
	}>, declarations:Map<String, HxiDeclaration>, span:SourceSpan,
			isUnion:Bool = false):TypedNativeLayout {
		var abi = HxiAbi.forTarget(target, declarations), placed:Array<TypedNativeFieldLayout> = [], cursor = 0, recordAlignment = 1;
		for (field in fields) {
			var hxiType = fieldType(field.type), layout = abi.layout(hxiType);
			if (layout == null || layout.size <= 0 || layout.align <= 0)
				throw 'Field "${field.name}" in native record "$name" has no fixed C layout';
			var fieldSize = field.arrayLength == null ? layout.size : layout.size * field.arrayLength;
			if (fieldSize <= 0 || fieldSize > 0x7FFFFFFF)
				throw 'Field "${field.name}" in native record "$name" exceeds the supported layout size';
			if (!isUnion)
				cursor = alignUp(cursor, layout.align);
			placed.push({
				name: field.name,
				offset: isUnion ? 0 : cursor,
				size: fieldSize,
				alignment: layout.align
			});
			if (cursor > 0x7FFFFFFF - fieldSize)
				throw 'Native record "$name" exceeds the supported layout size';
			cursor = isUnion ? Std.int(Math.max(cursor, fieldSize)) : cursor + fieldSize;
			recordAlignment = Std.int(Math.max(recordAlignment, layout.align));
		}
		return {
			target: target,
			size: alignUp(cursor, recordAlignment),
			alignment: recordAlignment,
			fields: placed
		};
	}

	static function alignUp(value:Int, alignment:Int):Int {
		var remainder = value % alignment;
		if (remainder == 0)
			return value;
		var padding = alignment - remainder;
		if (value > 0x7FFFFFFF - padding)
			throw "Native record layout exceeds the supported size";
		return value + padding;
	}
}
