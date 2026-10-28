package compiler.abi;

import compiler.abi.PatchPlanner.AbiChange;

/** Language-neutral code and entity identity for one ABI incompatibility. */
typedef AbiChangeRecord = {
	final code:String;
	final entityKind:String;
	final entityId:String;
}

/** Stable wire representation for ABI compatibility reasons. */
class AbiChangeSchema {
	public static inline final VERSION = 1;

	public static function encode(change:AbiChange):AbiChangeRecord
		return switch change {
			case FunctionAdded(name): record("function_added", "function", name);
			case FunctionRemoved(name): record("function_removed", "function", name);
			case FunctionSignatureChanged(name): record("function_signature_changed", "function", name);
			case ObjectAdded(name): record("object_added", "object", name);
			case ObjectRemoved(name): record("object_removed", "object", name);
			case ObjectLayoutChanged(name): record("object_layout_changed", "object", name);
			case ObjectFieldTypeChanged(name): record("object_field_type_changed", "object_field", name);
			case ObjectFieldReserveExhausted(name): record("object_field_reserve_exhausted", "object", name);
			case ObjectMethodDispatchChanged(name): record("object_method_dispatch_changed", "object_method", name);
			case ClosureLayoutChanged(name): record("closure_layout_changed", "closure_environment", name);
			case InterfaceChanged(name): record("interface_changed", "interface", name);
			case EnumChanged(name): record("enum_changed", "enum", name);
			case GlobalLayoutChanged(name): record("global_layout_changed", "global", name);
			case GeneratedFunctionsRenumbered(group): record("generated_functions_renumbered", "generated_function_group", group);
			case AssemblyLayoutChanged(detail): record("assembly_layout_changed", "module", detail);
		};

	public static function decode(version:Int, record:AbiChangeRecord):AbiChange {
		if (version != VERSION)
			throw 'Unsupported ABI change schema version $version';
		if (record == null || record.entityId == null)
			throw "Invalid ABI change record";
		return switch record.code {
			case "function_added": requireKind(record, "function", FunctionAdded(record.entityId));
			case "function_removed": requireKind(record, "function", FunctionRemoved(record.entityId));
			case "function_signature_changed": requireKind(record, "function", FunctionSignatureChanged(record.entityId));
			case "object_added": requireKind(record, "object", ObjectAdded(record.entityId));
			case "object_removed": requireKind(record, "object", ObjectRemoved(record.entityId));
			case "object_layout_changed": requireKind(record, "object", ObjectLayoutChanged(record.entityId));
			case "object_field_type_changed": requireKind(record, "object_field", ObjectFieldTypeChanged(record.entityId));
			case "object_field_reserve_exhausted": requireKind(record, "object", ObjectFieldReserveExhausted(record.entityId));
			case "object_method_dispatch_changed": requireKind(record, "object_method", ObjectMethodDispatchChanged(record.entityId));
			case "closure_layout_changed": requireKind(record, "closure_environment", ClosureLayoutChanged(record.entityId));
			case "interface_changed": requireKind(record, "interface", InterfaceChanged(record.entityId));
			case "enum_changed": requireKind(record, "enum", EnumChanged(record.entityId));
			case "global_layout_changed": requireKind(record, "global", GlobalLayoutChanged(record.entityId));
			case "generated_functions_renumbered": requireKind(record, "generated_function_group", GeneratedFunctionsRenumbered(record.entityId));
			case "assembly_layout_changed": requireKind(record, "module", AssemblyLayoutChanged(record.entityId));
			case unknown: throw 'Unknown ABI change code "$unknown"';
		};
	}

	static function requireKind(record:AbiChangeRecord, expected:String, result:AbiChange):AbiChange {
		if (record.entityKind != expected)
			throw 'ABI change ${record.code} requires entity kind "$expected"';
		return result;
	}

	static function record(code:String, entityKind:String, entityId:String):AbiChangeRecord
		return {code: code, entityKind: entityKind, entityId: entityId};
}
