package compiler.backend.wasm;

/** Value types supported by the self-hosted Wasm model. */
enum WasmValueType {
	I32;
	I64;
	F32;
	F64;
	Ref(type:WasmRefType);
}

/** A typed WebAssembly reference. */
typedef WasmRefType = {
	final nullable:Bool;
	final heap:WasmHeapType;
}

/** Abstract or module-defined heap type used by a reference. */
enum WasmHeapType {
	Any;
	Eq;
	I31;
	Struct;
	Array;
	Func;
	Extern;
	None;
	NoExtern;
	NoFunc;
	Exn;
	NoExn;
	Type(index:Int);
}

/** Storage used by a struct field or GC array element. */
enum WasmStorageType {
	Value(type:WasmValueType);
	I8;
	I16;
}

typedef WasmFieldType = {
	final type:WasmStorageType;
	final mutable:Bool;
}

enum WasmCompositeType {
	Func(type:WasmFunctionType);
	Struct(fields:Array<WasmFieldType>);
	Array(field:WasmFieldType);
}

/** A subtype declaration. Final types with no declared supertypes use the compact composite encoding. */
typedef WasmSubtype = {
	final finalType:Bool;
	final supertypes:Array<Int>;
	final composite:WasmCompositeType;
}

/** A type-section entry is either one subtype or an explicitly recursive group. */
enum WasmTypeGroup {
	Single(type:WasmSubtype);
	RecGroup(types:Array<WasmSubtype>);
}

typedef WasmFunctionType = {
	final parameters:Array<WasmValueType>;
	final results:Array<WasmValueType>;
}

/** Exception-table clauses branch to a surrounding label when their tag matches. */
enum WasmCatchClause {
	Tag(tag:Int, label:Int);
	CatchAll(label:Int);
}

/** Small, target-level instruction vocabulary. It deliberately knows no Haxeon IR. */
enum WasmInstruction {
	Unreachable;
	Nop;
	Block(result:Null<WasmValueType>);
	Loop(result:Null<WasmValueType>);
	Try(result:Null<WasmValueType>);
	TryTable(result:Null<WasmValueType>, catches:Array<WasmCatchClause>);
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
	I64LtU;
	I64LeS;
	F64Add;
	F64Sub;
	F64Mul;
	F64Div;
	F64Ceil;
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
	I64ReinterpretF64;
	F64ReinterpretI64;
	RefNull(heapType:WasmHeapType);
	RefIsNull;
	RefEq;
	RefTest(type:WasmRefType);
	RefCast(type:WasmRefType);
	StructNew(typeIndex:Int);
	StructNewDefault(typeIndex:Int);
	StructGet(typeIndex:Int, fieldIndex:Int);
	StructGetSigned(typeIndex:Int, fieldIndex:Int);
	StructGetUnsigned(typeIndex:Int, fieldIndex:Int);
	StructSet(typeIndex:Int, fieldIndex:Int);
	ArrayNew(typeIndex:Int);
	ArrayNewDefault(typeIndex:Int);
	ArrayGet(typeIndex:Int);
	ArrayGetSigned(typeIndex:Int);
	ArrayGetUnsigned(typeIndex:Int);
	ArraySet(typeIndex:Int);
	ArrayLen;
	ArrayCopy(destinationTypeIndex:Int, sourceTypeIndex:Int);
}
