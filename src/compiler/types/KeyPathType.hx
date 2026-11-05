package compiler.types;

import compiler.types.Type.CompilerType;

/** Shared carrier identity for readable and writable views of the same path type. */
class KeyPathType {
	public static function fields(root:CompilerType, value:CompilerType):Array<compiler.types.Type.AnonymousField>
		return [
			for (entry in [
				{name: "$get", type: TFunction([root], value)},
				{name: "$set", type: TFunction([root, value], root)},
				{name: "$key", type: TString}, {name: "$steps", type: TString},
				{name: "$tail", type: TString}, {name: "$display", type: TString},
				{name: "$writeback", type: TBool}
			]) {name: entry.name, type: entry.type, optional: false, isFinal: true}
		];

	public static function descriptorName(root:CompilerType, value:CompilerType):String
		return "$keypath$" + compiler.semantic.SemanticSignature.type(root) + ":" + compiler.semantic.SemanticSignature.type(value);

}
