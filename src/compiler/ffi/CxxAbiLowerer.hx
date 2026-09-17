package compiler.ffi;

import compiler.ffi.CxxModel.CxxAlias;
import compiler.ffi.CxxModel.CxxEnum;
import compiler.ffi.CxxModel.CxxFunction;
import compiler.ffi.CxxModel.CxxMethod;
import compiler.ffi.CxxModel.CxxModel;
import compiler.ffi.CxxModel.CxxRecord;
import compiler.ffi.CxxModel.CxxType;
import compiler.ffi.HxiModel.HxiDeclaration;
import compiler.ffi.HxiModel.HxiField;
import compiler.ffi.HxiModel.HxiInterface;
import compiler.ffi.HxiModel.HxiParameter;
import compiler.ffi.HxiModel.HxiType;
import compiler.ffi.HxiModel.HxiOwnership;
import compiler.ffi.HxiModel.HxiHandleDisposition;
import compiler.ffi.HxiModel.HxiResultPolicy;
import compiler.ffi.NativeCallPlan.NativeDispatch;
import haxe.Int64;
import sys.FileSystem;

/** Lowers supported C++ declarations into ordinary HXI ABI declarations. */
class CxxAbiLowerer {
	public static function lower(model:CxxModel, target:String, ?library:String, ?interfaceName:String, ?dependencies:Array<String>,
			trivialValues:Bool = false, lifetimes:Bool = false, virtualDispatch:Bool = false, cxxThunks:Bool = false):HxiInterface {
		CxxSubsetValidator.throwIfInvalid(model, trivialValues, lifetimes, virtualDispatch, cxxThunks);
		if (cxxThunks)
			CxxThunkGenerator.prepare(model);
		var records:Map<String, CxxRecord> = [],
			enums:Map<String, CxxEnum> = [],
			aliases:Map<String, CxxAlias> = [];
		for (record in model.records)
			records.set(record.qualifiedName, record);
		for (enumModel in model.enums)
			enums.set(enumModel.qualifiedName, enumModel);
		for (alias in model.aliases)
			aliases.set(alias.qualifiedName, alias);
		var valueRecords:Map<String, Bool> = [];
		for (functionModel in model.functions) {
			markValueType(functionModel.result, true, records, aliases, valueRecords, []);
			for (parameter in functionModel.parameters)
				markValueType(parameter.type, true, records, aliases, valueRecords, []);
		}
		for (record in model.records)
			for (method in record.methods) {
				markValueType(method.result, true, records, aliases, valueRecords, []);
				for (parameter in method.parameters)
					markValueType(parameter.type, true, records, aliases, valueRecords, []);
			}
		var declarations:Array<HxiDeclaration> = [];
		for (record in model.records)
			declarations.push(lowerRecord(record, trivialValues, valueRecords, records, enums, aliases));
		for (enumModel in model.enums)
			declarations.push(lowerEnum(enumModel, enums, records, aliases));
		for (alias in model.aliases)
			declarations.push(Alias(hxiName(alias.qualifiedName), lowerType(alias.target, records, enums, aliases, true), alias.span));
		var used:Map<String, Bool> = [];
		for (functionModel in model.functions) {
			var name = uniqueName("__cxx_" + sanitize(functionModel.qualifiedName), functionModel.symbol, used);
			functionModel.loweredName = name;
			declarations.push(lowerFunction(functionModel, name, records, enums, aliases));
		}
		for (record in model.records)
			for (method in record.methods) {
				var name = uniqueName("__cxx_" + sanitize(method.qualifiedName), method.symbol, used);
				method.loweredName = name;
				declarations.push(lowerMethod(method, name, records, enums, aliases));
			}
		declarations.sort(function(left, right) return Reflect.compare(declarationName(left), declarationName(right)));
		var source = model.span.file;
		return new HxiInterface(interfaceName == null ? moduleName(model.header) : interfaceName, target, library,
			dependencies == null ? [] : dependencies.copy(), declarations, source.span(0, source.bytes.length));
	}

	/** Returns the C++-specific dispatch metadata for already lowered declarations. */
	public static function dispatches(model:CxxModel):Map<String, NativeDispatch> {
		var result:Map<String, NativeDispatch> = [];
		for (functionModel in model.functions)
			if (functionModel.loweredName != null)
				result.set(functionModel.loweredName, DirectSymbol);
		for (record in model.records)
			for (method in record.methods)
				if (method.loweredName != null)
					result.set(method.loweredName,
						method.isConstructor ? CxxConstructor : method.isDestructor ? CxxDestructor : method.thunkSymbol != null ? DirectSymbol : method.virtualAbi == null ? DirectSymbol : CxxVirtual(method.virtualAbi.vtableIndex,
							method.virtualAbi.thisAdjustment));
		return result;
	}

	static function lowerRecord(record:CxxRecord, trivialValues:Bool, valueRecords:Map<String, Bool>, records:Map<String, CxxRecord>,
			enums:Map<String, CxxEnum>, aliases:Map<String, CxxAlias>):HxiDeclaration {
		if (!valueRecords.exists(record.qualifiedName)
			|| !trivialValues
			|| !record.isStandardLayout
			|| !record.isTriviallyCopyable
			|| record.bases.length != 0
			|| record.hasVirtualMembers)
			return Opaque(hxiName(record.qualifiedName), record.span);
		var fields:Array<HxiField> = [];
		for (field in record.fields)
			fields.push({
				name: field.name,
				type: lowerType(field.type, records, enums, aliases, false),
				offset: field.offset,
				ownership: HxiOwnership.Unspecified,
				handleDisposition: HxiHandleDisposition.Unspecified,
				lengthField: null,
				structSize: false,
				metadata: [],
				span: field.span
			});
		return Structure(hxiName(record.qualifiedName), record.size, record.align, fields, record.span);
	}

	static function lowerEnum(enumModel:CxxEnum, enums:Map<String, CxxEnum>, records:Map<String, CxxRecord>, aliases:Map<String, CxxAlias>):HxiDeclaration {
		var values = [
			for (value in enumModel.values)
				{name: value.name, value: Int64.parseString(value.value), span: value.span}
		];
		return Enumeration(hxiName(enumModel.qualifiedName), lowerType(enumModel.underlying, records, enums, aliases, true), false, values, enumModel.span);
	}

	static function lowerFunction(functionModel:CxxFunction, name:String, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>):HxiDeclaration {
		return Function(name, parameters(functionModel.parameters, records, enums, aliases), lowerType(functionModel.result, records, enums, aliases, true),
			functionModel.thunkSymbol == null ? functionModel.symbol : functionModel.thunkSymbol, false, "cdecl", resultPolicy(functionModel.result),
			functionModel.span);
	}

	static function lowerMethod(method:CxxMethod, name:String, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>):HxiDeclaration {
		var parameters = parameters(method.parameters, records, enums, aliases);
		if (!method.isStatic) {
			var ownerType:HxiType = Named(hxiName(method.owner));
			parameters.unshift({
				name: "__this",
				type: Pointer(method.isConst ? Const(ownerType) : ownerType),
				direction: In,
				ownership: Unspecified,
				handleDisposition: Unspecified,
				retained: false,
				metadata: [],
				span: method.span
			});
		}
		return Function(name, parameters, lowerType(method.result, records, enums, aliases, true),
			method.thunkSymbol == null ? method.symbol : method.thunkSymbol, false, "cdecl", resultPolicy(method.result), method.span);
	}

	static function parameters(parameters:Array<CxxModel.CxxParameter>, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>,
			aliases:Map<String, CxxAlias>):Array<HxiModel.HxiParameter> {
		return [
			for (parameter in parameters)
				{
					name: parameter.name,
					type: lowerType(parameter.type, records, enums, aliases, false),
					direction: In,
					ownership: Unspecified,
					handleDisposition: Unspecified,
					retained: false,
					metadata: [],
					span: parameter.span
				}
		];
	}

	static function lowerType(type:CxxType, records:Map<String, CxxRecord>, enums:Map<String, CxxEnum>, aliases:Map<String, CxxAlias>, allowVoid:Bool):HxiType {
		return switch type {
			case CxxVoid: Primitive("void");
			case CxxPrimitive(name): Primitive(name);
			case CxxConst(element): Const(lowerType(element, records, enums, aliases, allowVoid));
			case CxxPointer(element): Pointer(lowerType(element, records, enums, aliases, false));
			case CxxReference(element): Pointer(lowerType(element, records, enums, aliases, false));
			case CxxNamed(name):
				if (!records.exists(name) && !enums.exists(name) && !aliases.exists(name))
					throw 'CXX012 unknown type "$name"';
				Named(hxiName(name));
			case CxxRValueReference(_): throw "CXX001 rvalue references are unsupported by CXX_ABI_V1";
			case CxxUnsupported(raw, reason): throw 'CXX009 unsupported C++ type "$raw": $reason';
		};
	}

	static function resultPolicy(type:CxxType):HxiResultPolicy {
		var borrowed = pointerResult(type),
			metadata:Map<String, Array<String>> = [];
		if (borrowed)
			metadata.set("borrowed", []);
		return {
			ownership: borrowed ? Borrowed : Unspecified,
			handleDisposition: Unspecified,
			length: null,
			metadata: metadata
		};
	}

	static function pointerResult(type:CxxType):Bool
		return switch type {
			case CxxPointer(_) | CxxReference(_): true;
			case CxxConst(element): pointerResult(element);
			case _: false;
		};

	static function markValueType(type:CxxType, byValue:Bool, records:Map<String, CxxRecord>, aliases:Map<String, CxxAlias>, valueRecords:Map<String, Bool>,
			visiting:Array<String>):Void {
		switch type {
			case CxxConst(element):
				markValueType(element, byValue, records, aliases, valueRecords, visiting);
			case CxxPointer(element) | CxxReference(element):
				markValueType(element, false, records, aliases, valueRecords, visiting);
			case CxxNamed(name) if (byValue && records.exists(name)):
				valueRecords.set(name, true);
			case CxxNamed(name) if (byValue && aliases.exists(name) && visiting.indexOf(name) < 0):
				var alias = aliases.get(name);
				visiting.push(name);
				markValueType(alias.target, true, records, aliases, valueRecords, visiting);
				visiting.pop();
			case _:
		}
	}

	static function uniqueName(base:String, symbol:String, used:Map<String, Bool>):String {
		var name = base;
		if (used.exists(name))
			name = base + "_" + StringTools.hex(hash(symbol), 8).toLowerCase();
		while (used.exists(name))
			name += "_";
		used.set(name, true);
		return name;
	}

	static function hash(value:String):Int {
		var result:Int = cast 0x811C9DC5;
		for (index in 0...value.length)
			result = (result ^ value.charCodeAt(index)) * 16777619;
		return result;
	}

	public static function hxiNameForQualified(name:String):String
		return hxiName(name);

	static function hxiName(name:String):String
		return "__cxx_" + sanitize(name);

	static function sanitize(name:String):String {
		var result = new StringBuf();
		for (index in 0...name.length) {
			var code = name.charCodeAt(index);
			if ((code >= "a".code && code <= "z".code)
				|| (code >= "A".code && code <= "Z".code)
				|| (code >= "0".code && code <= "9".code)
				|| code == "_".code)
				result.addChar(code);
			else
				result.add("_");
		}
		return result.toString();
	}

	static function declarationName(declaration:HxiDeclaration):String
		return switch declaration {
			case Opaque(name, _) | Alias(name, _, _) | Handle(name, _, _, _) | Constant(name, _, _) | Structure(name, _, _, _, _) |
				Enumeration(name, _, _, _, _) | Callback(name, _, _, _, _) | Function(name, _, _, _, _, _, _, _): name;
		};

	static function moduleName(path:String):String {
		var name = path.split("/").pop();
		return StringTools.replace(name, ".", "_");
	}
}
