import typeinfo_generic.Records.FlatRecord;
import typeinfo_generic.Records.Rich;
import typeinfo_generic.Registry;
import typeinfo_generic.Registry.TypeKey;

class Main {
	static function main():Int {
		var flatInfo = typeInfo<FlatRecord>(),
			richInfo = typeInfo<Rich>(),
			flat = Registry.register(new TypeKey<FlatRecord>()),
			rich = Registry.nested(new TypeKey<Rich>());
		if (flat.identity != flatInfo.type || flat.name != flatInfo.name || flat.hash != flatInfo.hash || flat.hash.length != 64)
			return 1;
		if (flat.size != sizeof<FlatRecord>()
			|| flat.size != flatInfo.size
			|| flat.alignment != alignof<FlatRecord>()
			|| flat.alignment != flatInfo.alignment
			|| flat.fieldType != "Int"
			|| flat.fieldType != flatInfo.fields[0].type
			|| flat.fieldSize != sizeof<Int>()
			|| flat.fieldSize != flatInfo.fields[0].size
			|| flat.fieldAlignment != alignof<Int>()
			|| flat.fieldAlignment != flatInfo.fields[0].alignment
			|| flat.fieldOffset != offsetof<FlatRecord>("x"))
			return 2;
		if (rich.identity != richInfo.type || rich.name != richInfo.name || rich.hash != richInfo.hash || rich.hash.length != 64)
			return 3;
		if (rich.size != null || rich.alignment != null || rich.fieldType != "class:typeinfo_generic.FlatRecord<>")
			return 4;
		if (rich.size != richInfo.size
			|| rich.alignment != richInfo.alignment
			|| rich.fieldType != richInfo.fields[0].type
			|| rich.fieldSize != sizeof<FlatRecord>()
			|| rich.fieldSize != richInfo.fields[0].size
			|| rich.fieldAlignment != alignof<FlatRecord>()
			|| rich.fieldAlignment != richInfo.fields[0].alignment
			|| rich.fieldOffset != richInfo.fields[0].offset)
			return 5;
		if (rich.nestedFieldType != "Int"
			|| rich.nestedFieldType != richInfo.fields[0].fields[0].type
			|| rich.nestedFieldSize != sizeof<Int>()
			|| rich.nestedFieldSize != richInfo.fields[0].fields[0].size
			|| rich.nestedFieldAlignment != alignof<Int>()
			|| rich.nestedFieldAlignment != richInfo.fields[0].fields[0].alignment
			|| rich.nestedFieldOffset != offsetof<FlatRecord>("x"))
			return 6;
		return 42;
	}
}
