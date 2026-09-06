package compiler.types;

import compiler.types.Type.CompilerType;

/** Structured identity and deterministic naming for generated generic ABI bodies. */
typedef GenericSpecialization = {
	final origin:String;
	final representations:Array<CompilerType>;
	final name:String;
	final isNew:Bool;
}

class GenericSpecializationRegistry {
	final names:Map<String, String> = [];

	public function new() {}

	public function copy():GenericSpecializationRegistry {
		var result = new GenericSpecializationRegistry();
		for (key => name in names)
			result.names.set(key, name);
		return result;
	}

	public function request(origin:String, representations:Array<CompilerType>):GenericSpecialization {
		var signature = [for (type in representations) SemanticSignature.type(type)].join(","),
			key = origin + "<" + signature + ">";
		if (names.exists(key))
			return {
				origin: origin,
				representations: representations.copy(),
				name: names.get(key),
				isNew: false
			};
		var name = '$' + 'generic:$key';
		names.set(key, name);
		return {
			origin: origin,
			representations: representations.copy(),
			name: name,
			isNew: true
		};
	}
}
