import compiler.semantic.SemanticSignature;
import compiler.semantic.SemanticTypeMap;
import compiler.types.Type.CompilerType;
import compiler.types.Type.MonomorphCell;
import compiler.types.Type.NominalKind;

/** `SemanticTypeMap` keys types as `SemanticSignature.type` spells them: equal spellings are the same key, others are not. */
class SemanticTypeMapMain {
	static function main():Void {
		var filled = new MonomorphCell("the type of local \"x\"", null, false);
		filled.bound = TMap(TString, TInt);
		var types:Array<CompilerType> = [
			TInt, TInt64, TBool, TFloat, TString, TBytes, THlBytes, TDynamic, TNever, TRange, TVoid, TNull,
			TNativeAbstract("hl_bytes_map"), TNativeAbstract("hl_int_map"), TNativeScalar("f32"),
			TTypeParameter("Box", "T"), TTypeParameter("Box", "U"), TTypeParameter("Pair", "T"),
			TInstance(NominalKind.Class, "Box", [TInt]), TInstance(NominalKind.Class, "Box", [TString]),
			TInstance(NominalKind.Interface, "Box", [TInt]), TInstance(NominalKind.Enum, "Option", []),
			TInstance(NominalKind.Class, "Box", []),
			TAbstract("Id", [], TInt), TAbstract("Id", [], TString), TAbstract("Id", [TInt], TInt),
			TNullable(TInt), TArray(TInt), TIterator(TInt), TArray(TArray(TInt)), TMap(TString, TInt),
			TMap(TInt, TString),
			TKeyPath(TString, TInt, false), TKeyPath(TString, TInt, true),
			TFunction([TInt, TString], TVoid, []), TFunction([TInt, TString], TVoid, [false, true]),
			TFunction([TInt, TString], TVoid, [false, true, false]), TFunction([TInt], TVoid, []),
			TFunction([TInt, TString], TInt, []), TAnonymous("$anon:{x:Int}", []), TAnonymous("$anon:{y:Int}", []),
			TMonomorph(filled), TMonomorph(new MonomorphCell("the type of local \"y\"", null, false)),
			];
		var map = new SemanticTypeMap<Int>();
		for (index in 0...types.length)
			for (other in 0...types.length) {
				var left = types[index],
					right = types[other],
					spelledSame = SemanticSignature.type(left) == SemanticSignature.type(right);
				if (SemanticTypeMap.same(left, right) != spelledSame)
					throw 'same disagrees with the spelling for ${SemanticSignature.type(left)} and ${SemanticSignature.type(right)}';
				if (spelledSame && SemanticTypeMap.hash(left) != SemanticTypeMap.hash(right))
					throw 'hash differs for ${SemanticSignature.type(left)}';
			}
		for (index in 0...types.length)
			if (map.get(types[index]) == null)
				map.set(types[index], index);
		for (index in 0...types.length) {
			var found = map.get(types[index]);
			if (found == null || SemanticSignature.type(types[found]) != SemanticSignature.type(types[index]))
				throw 'lookup of ${SemanticSignature.type(types[index])} found the wrong key';
		}
		if (map.get(TMap(TString, TBool)) != null)
			throw "an absent type was found";
		Sys.println("PASS: SemanticTypeMap keys types by their spelling");
	}
}
