package typeinfo_generic;

class TypeKey<T> {}

class Component<T> {
	public final identity:String;
	public final name:String;
	public final hash:String;
	public final size:Null<Int>;
	public final alignment:Null<Int>;
	public final fieldType:String;
	public final fieldSize:Null<Int>;
	public final fieldAlignment:Null<Int>;
	public final fieldOffset:Null<Int>;
	public final nestedFieldType:String;
	public final nestedFieldSize:Null<Int>;
	public final nestedFieldAlignment:Null<Int>;
	public final nestedFieldOffset:Null<Int>;

	public function new(identity:String, name:String, hash:String, size:Null<Int>, alignment:Null<Int>, fieldType:String, fieldSize:Null<Int>,
			fieldAlignment:Null<Int>, fieldOffset:Null<Int>, nestedFieldType:String, nestedFieldSize:Null<Int>, nestedFieldAlignment:Null<Int>,
			nestedFieldOffset:Null<Int>) {
		this.identity = identity;
		this.name = name;
		this.hash = hash;
		this.size = size;
		this.alignment = alignment;
		this.fieldType = fieldType;
		this.fieldSize = fieldSize;
		this.fieldAlignment = fieldAlignment;
		this.fieldOffset = fieldOffset;
		this.nestedFieldType = nestedFieldType;
		this.nestedFieldSize = nestedFieldSize;
		this.nestedFieldAlignment = nestedFieldAlignment;
		this.nestedFieldOffset = nestedFieldOffset;
	}
}

class Registry {
	public static function register<T>(key:TypeKey<T>):Component<T> {
		var info = typeInfo<T>(), first = info.fields[0], nested = first;
		if (first.fields.length > 0)
			nested = first.fields[0];
		return new Component<T>(info.type, info.name, info.hash, info.size, info.alignment, first.type, first.size, first.alignment, first.offset,
			nested.type, nested.size, nested.alignment, nested.offset);
	}

	public static function nested<T>(key:TypeKey<T>):Component<T>
		return relay(key);

	static function relay<T>(key:TypeKey<T>):Component<T>
		return register(key);
}
