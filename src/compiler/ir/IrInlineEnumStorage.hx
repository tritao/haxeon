package compiler.ir;

import compiler.ir.Ir;

/** The logical enum remains public; only typed storage uses its private value record. */
class IrInlineEnumStorage {
	public static function resolve(enums:Array<IrEnum>, objects:IrObjectTable, name:String):Null<IrType> {
		for (declaration in enums) if (declaration.name == name) {
			if (declaration.inlineStorage == null) return null;
			validate(declaration, objects);
			return Obj(declaration.inlineStorage);
		}
		throw 'Unknown enum "$name"';
	}

	public static function validate(declaration:IrEnum, objects:IrObjectTable):Void {
		var name = declaration.inlineStorage;
		if (name == null) return;
		var object = objects.get(name);
		if (declaration.isRecursive == true || name != IrInlineEnumLayout.VALUE_PREFIX + declaration.name
			|| object == null || !object.isValue || object.base != null || object.interfaces.length != 0 || object.methods.length != 0)
			throw 'Invalid inline storage for enum "${declaration.name}"';
		if (object.fields.length == 0 || object.fields[0].name != "tag" || !IrVerifier.sameType(object.fields[0].type, I32))
			throw 'Inline enum storage "$name" requires an Int tag';
		var scalar = 0, reference = 0, width = 0, referencesStarted = false;
		for (index in 1...object.fields.length) {
			var field = object.fields[index];
			if (!referencesStarted && field.name == 'scalar$scalar') {
				var bits = switch field.type { case I32: 32; case I64: 64; default: 0; };
				if (bits == 0 || width != 0 && bits != width) throw 'Invalid scalar word in inline enum storage "$name"';
				width = bits; scalar++;
			} else {
				referencesStarted = true;
				if (field.name != 'reference$reference' || !IrValueLaneReference.isCarrier(field.type))
					throw 'Invalid reference slot in inline enum storage "$name"';
				reference++;
			}
		}
	}
}
