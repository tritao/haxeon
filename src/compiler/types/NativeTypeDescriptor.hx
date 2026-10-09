package compiler.types;

import haxe.crypto.Sha256;

/** Source facts included in the first native value descriptor representation. */
typedef NativeTypeDescriptorField = {
	final name:String;
	final offset:Int;
	final type:String;
	final annotations:Array<String>;
}

/** Stable content hashing for compiler-emitted type descriptors. */
class NativeTypeDescriptor {
	public static function contentHash(identity:String, name:String, size:Int, alignment:Int, fields:Array<NativeTypeDescriptorField>):String {
		var canonical = new StringBuf();
		append(canonical, identity);
		append(canonical, name);
		append(canonical, Std.string(size));
		append(canonical, Std.string(alignment));
		append(canonical, Std.string(fields.length));
		for (field in fields) {
			append(canonical, field.name);
			append(canonical, Std.string(field.offset));
			append(canonical, field.type);
			append(canonical, Std.string(field.annotations.length));
			for (annotation in field.annotations)
				append(canonical, annotation);
		}
		return Sha256.encode(canonical.toString());
	}

	static function append(buffer:StringBuf, value:String):Void {
		buffer.add(value.length);
		buffer.add(":");
		buffer.add(value);
	}
}
