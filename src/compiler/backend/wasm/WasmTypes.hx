package compiler.backend.wasm;

/** Value types currently supported by the self-hosted Wasm model. */
enum WasmValueType {
	I32;
	I64;
	F32;
	F64;
}

typedef WasmFunctionType = {
	final parameters:Array<WasmValueType>;
	final results:Array<WasmValueType>;
}

/** Small, target-level instruction vocabulary. It deliberately knows no Haxeon IR. */
enum WasmInstruction {
	Unreachable;
	Nop;
	Block(result:Null<WasmValueType>);
	Loop(result:Null<WasmValueType>);
	Try(result:Null<WasmValueType>);
	If(result:Null<WasmValueType>);
	Else;
	Catch(tag:Int);
	End;
	Br(depth:Int);
	BrIf(depth:Int);
	BrTable(targets:Array<Int>, defaultDepth:Int);
	Return;
	Throw(tag:Int);
	Call(functionIndex:Int);
	CallIndirect(typeIndex:Int);
	MemoryCopy;
	MemoryFill;
	MemorySize;
	MemoryGrow;
	Drop;
	LocalGet(index:Int);
	LocalSet(index:Int);
	LocalTee(index:Int);
	GlobalGet(index:Int);
	GlobalSet(index:Int);
	I32Load(offset:Int);
	I32Load8S(offset:Int);
	I32Load8U(offset:Int);
	I32Load16S(offset:Int);
	I32Load16U(offset:Int);
	I32Store(offset:Int);
	I32Store8(offset:Int);
	I32Store16(offset:Int);
	I64Load(offset:Int);
	I64Store(offset:Int);
	F32Load(offset:Int);
	F32Store(offset:Int);
	F64Load(offset:Int);
	F64Store(offset:Int);
	I32Const(value:Int);
	I64Const(value:Int);
	F64Const(value:Float);
	I32Add;
	I32Sub;
	I32Mul;
	I32DivS;
	I32RemS;
	I32And;
	I32Xor;
	I32Or;
	I32Shl;
	I32ShrS;
	I32ShrU;
	I32Eqz;
	I32Eq;
	I32LtS;
	I32LeS;
	I64Add;
	I64Sub;
	I64Mul;
	I64DivS;
	I64RemS;
	I64And;
	I64Xor;
	I64Or;
	I64Shl;
	I64ShrS;
	I64ShrU;
	I64Eqz;
	I64Eq;
	I64LtS;
	I64LeS;
	F64Add;
	F64Sub;
	F64Mul;
	F64Div;
	F64Eq;
	F64Lt;
	F64Le;
	F64ConvertI32S;
	F64ConvertI64S;
	I64ExtendI32S;
	I64ExtendI32U;
	F64PromoteF32;
	F32DemoteF64;
	I32WrapI64;
	I32TruncF64S;
}
