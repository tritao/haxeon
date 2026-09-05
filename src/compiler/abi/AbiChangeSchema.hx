package compiler.abi;

import compiler.abi.PatchPlanner.AbiChange;

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
			case ClosureLayoutChanged(name): record("closure_layout_changed", "closure_environment", name);
			case InterfaceChanged(name): record("interface_changed", "interface", name);
			case EnumChanged(name): record("enum_changed", "enum", name);
			case GlobalLayoutChanged(name): record("global_layout_changed", "global", name);
		};

	static function record(code:String, entityKind:String, entityId:String):AbiChangeRecord
		return {code: code, entityKind: entityKind, entityId: entityId};
}
