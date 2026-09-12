import compiler.ffi.CHeaderEmitter;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.codec.IrTypeCodec;
import compiler.ir.codec.IrValueTableCodec;
import haxe.io.BytesOutput;

class ManagedBytesMain {
	static function main():Void {
		expect(IrTypeCodec.decode(IrTypeCodec.encode(ManagedBytes)) == ManagedBytes, "managed byte IR type must round-trip");

		var legacyType = new BytesOutput();
		legacyType.bigEndian = false;
		legacyType.writeString("IRT");
		legacyType.writeByte(1);
		legacyType.writeByte(1);
		expect(IrTypeCodec.decode(legacyType.getBytes()) == I32, "legacy IR type state must remain readable");

		var value = new IrValue(0, "bytes", ManagedBytes),
			values = IrValueTableCodec.decode(IrValueTableCodec.encode([value]));
		expect(values.length == 1 && values[0].type == ManagedBytes, "managed byte values must persist in value tables");

		var builder = new IrBuilder(),
			argument = builder.argument("bytes", ManagedBytes);
		builder.returnValue(argument);
		var fn = new IrFunction("identity", builder.arguments, ManagedBytes, builder.blocks),
			restoredFunction = IrFunctionStateCodec.decode(IrFunctionStateCodec.encode(fn));
		expect(restoredFunction.result == ManagedBytes && restoredFunction.arguments[0].type == ManagedBytes,
			"managed byte signatures must persist in incremental function state");

		var program = new IrProgram("identity");
		program.functions = [fn];
		var restoredProgram = CanonicalIrCodec.decode(CanonicalIrCodec.encode(program));
		expect(restoredProgram.functions[0].result == ManagedBytes, "managed byte signatures must persist in canonical IR");

		var symbols = new HlSymbolTable(),
			managedBytesIndex = symbols.internType(ManagedBytes),
			runtimeAbstractIndex = symbols.internType(Abstract("realtime_bytes"));
		expect(managedBytesIndex == runtimeAbstractIndex, "managed bytes must share the runtime abstract HashLink type");

		var header = CHeaderEmitter.emit([
			{
				name: "bytes.consume",
				library: "bytes",
				symbol: "consume",
				arguments: [ManagedBytes],
				result: Void
			}
		], "bytes");
		expect(header.indexOf("HL_PRIM void bytes_consume(void * arg0);") >= 0
			&& header.indexOf("DEFINE_PRIM(_VOID, consume, _ABSTRACT(realtime_bytes));") >= 0
			&& header.indexOf("realtime_bytes *") < 0,
			"C headers must keep managed byte storage opaque while preserving the HashLink ABI type");

		Sys.println("PASS: managed byte ABI type, persistence, and backend representation");
	}

	static function expect(condition:Bool, message:String):Void
		if (!condition)
			throw message;
}
