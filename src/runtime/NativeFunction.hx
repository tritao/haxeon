package runtime;

import haxe.io.Bytes;

/** Prepared ordinary C function with a fixed, validated scalar/pointer signature. */
class NativeFunction {
	static inline final SLOT_SIZE = 8;

	final handle:hl.Abstract<"native_function">;
	final arguments:Array<NativeType>;

	public final result:NativeType;

	public function new(handle:hl.Abstract<"native_function">, arguments:Array<NativeType>, result:NativeType) {
		this.handle = handle;
		this.arguments = arguments.copy();
		this.result = result;
	}

	/** Invoke using one native-endian eight-byte slot per argument and result. */
	public function callRaw(argumentSlots:Bytes):Bytes {
		if (argumentSlots.length != arguments.length * SLOT_SIZE)
			throw new NativeCallError("Native argument buffer has the wrong size");
		var output = Bytes.alloc(SLOT_SIZE),
			status = NativeCallApi.native_call(handle, argumentSlots.getData(), argumentSlots.length, output.getData(), output.length);
		if (status != 0)
			throw new NativeCallError(NativeCallApi.lastError());
		return output;
	}

	public function callI32(values:Array<Int>):Int {
		if (values.length != arguments.length)
			throw new NativeCallError("Native argument count does not match the function signature");
		var slots = Bytes.alloc(values.length * SLOT_SIZE);
		for (index in 0...values.length) {
			if (arguments[index] != NativeType.I32 && arguments[index] != NativeType.U32)
				throw new NativeCallError("callI32 only accepts 32-bit integer arguments");
			slots.setInt32(index * SLOT_SIZE, values[index]);
		}
		if (result != NativeType.I32 && result != NativeType.U32)
			throw new NativeCallError("callI32 requires a 32-bit integer result");
		return callRaw(slots).getInt32(0);
	}

	public function callF64(values:Array<Float>):Float {
		if (values.length != arguments.length)
			throw new NativeCallError("Native argument count does not match the function signature");
		var slots = Bytes.alloc(values.length * SLOT_SIZE);
		for (index in 0...values.length) {
			if (arguments[index] != NativeType.F64)
				throw new NativeCallError("callF64 only accepts double arguments");
			slots.setDouble(index * SLOT_SIZE, values[index]);
		}
		if (result != NativeType.F64)
			throw new NativeCallError("callF64 requires a double result");
		return callRaw(slots).getDouble(0);
	}
}
