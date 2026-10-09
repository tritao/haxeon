package haxe.io;

/** Shared storage for generated HXI buffer abstracts; each abstract supplies its validated layout. */
class StructBufferStorage {
	public final bytes:Bytes;
	public final length:Int;
	final stride:Int;

	public function new(length:Int, stride:Int, structSizeOffset:Int) {
		if (stride <= 0 || length < 0 || length > 268435456 / stride)
			throw "HXI packed buffer exceeds the 256 MiB safety limit";
		this.length = length;
		this.stride = stride;
		bytes = Bytes.alloc(length * stride);
		if (structSizeOffset >= 0)
			for (index in 0...length) StructBufferNative.setI32(bytes, index * stride + structSizeOffset, stride);
	}

	public function offset(index:Int):Int {
		if (index < 0 || index >= length) throw "HXI packed buffer index out of bounds";
		return index * stride;
	}
}

/** HXI fields use native byte order rather than the portable Bytes encoding. */
extern class StructBufferNative {
	@:hlNative("haxeon_runtime", "setI32")
	static function setI32(bytes:Bytes, offset:Int, value:Int):Void;
}
