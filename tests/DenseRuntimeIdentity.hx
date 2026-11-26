import haxe.io.Bytes;
import haxe.io.BytesOutput;

/**
 * HLI 3, which binds stable ids the compiler minted to the slots of a dense module: what the runtime tests that build HLB 8
 * modules and HLP 11 patches by hand load them with. The compiler writes HLI 4, whose ids the loader mints.
 */
class DenseRuntimeIdentity {
	public static function encode(moduleId:Bytes, revision:Int, indices:Map<String, Int>,
			stableIds:Map<String, Int>):Bytes {
		var names = [for (name in stableIds.keys()) if (indices.exists(name)) name];
		names.sort(Reflect.compare);
		var out = new BytesOutput();
		out.bigEndian = false;
		out.writeString("HLI");
		out.writeByte(3);
		out.write(moduleId);
		out.writeInt32(revision);
		out.writeInt32(names.length);
		var initializer = indices.get("__init");
		out.writeInt32(initializer == null ? -1 : initializer);
		for (name in names) {
			out.writeInt32(stableIds.get(name));
			out.writeInt32(indices.get(name));
		}
		return out.getBytes();
	}
}
