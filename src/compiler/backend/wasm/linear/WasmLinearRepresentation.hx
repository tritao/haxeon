package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.IrFunction;
import compiler.backend.wasm.WasmScalarAbi;
import compiler.backend.wasm.WasmScalarLocals;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrCNativeArgumentMode;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmCAbi;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmRepresentation.WasmAggregateRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmInteropRepresentation;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.WasmRepresentation.WasmValueRepresentation;

/** Linear32 representation: managed references remain i32 pointers into the custom heap. */
class WasmLinearRepresentation implements WasmValueRepresentation implements WasmAggregateRepresentation implements WasmInteropRepresentation {
	final layout:WasmLayout;
	final allocator:Int;
	final bytesDataPointer:Int;
	final cstringCopy:Int;
	final valueObjects:Map<String, Bool> = [];
	final scalarAbi:Null<WasmScalarAbi>;
	final scalarLocals:Null<WasmScalarLocals>;
	final scalarResults:Map<Int, Array<Int>> = [];
	final scalarResultTypes:Map<Int, Array<IrType>> = [];
	final allocateLocal:Null<WasmValueType->Int>;
	final functions:Null<Map<String, Int>>;
	public final staticClosureDescriptors:Map<String, Int>;
	public final closureAdapters:Null<WasmLinearClosureAdapters>;

	public function new(layout:WasmLayout, allocator:Int, bytesDataPointer:Int, cstringCopy:Int, ?scalarAbi:WasmScalarAbi,
			?functions:Map<String, Int>, ?fn:IrFunction, ?allocateLocal:WasmValueType->Int, ?staticClosureDescriptors:Map<String, Int>,
			?closureAdapters:WasmLinearClosureAdapters) {
		this.layout = layout;
		this.allocator = allocator;
		this.bytesDataPointer = bytesDataPointer;
		this.cstringCopy = cstringCopy;
		this.scalarAbi = scalarAbi;
		this.functions = functions;
		this.staticClosureDescriptors = staticClosureDescriptors == null ? [] : staticClosureDescriptors;
		this.closureAdapters = closureAdapters;
		this.allocateLocal = allocateLocal;
		for (object in layout.program.objects) if (object.isValue && object.nativeLayout == null) valueObjects.set(object.name, true);
		scalarLocals = scalarAbi == null || allocateLocal == null ? null :
			new WasmScalarLocals(fn, scalarAbi.isValue, physicalFields, valueType, allocateLocal);
		if (scalarAbi != null && allocateLocal != null && fn != null) for (block in fn.blocks) for (located in block.instructions)
			switch located.value {
				case Call(out, name, _) if (scalarAbi.signatures.exists(name)):
					var signature = scalarAbi.signatures.get(name);
					if (signature.mutatesReceiver || scalarAbi.isValue(signature.result)) reserveScalarResults(out, scalarAbi.resultTypes(signature));
				case MethodCall(out, receiver, method, _, _) if (scalarAbi.scalarVirtuals.exists(WasmScalarAbi.virtualKey(receiver.type, method))):
					var virtual = scalarAbi.scalarVirtuals.get(WasmScalarAbi.virtualKey(receiver.type, method));
					if (virtual == null) throw "Missing scalar virtual signature";
					if (scalarAbi.isValue(virtual.signature.result)) reserveScalarResults(out, scalarAbi.valueTypes(virtual.signature.result));
				case CallClosure(out, closure, _) if (scalarAbi.scalarClosures.exists(Std.string(closure.type))):
					if (scalarAbi.isValue(out.type)) reserveScalarResults(out, scalarAbi.valueTypes(out.type));
				default:
			}
	}

	function reserveScalarResults(output:IrValue, types:Array<IrType>):Void {
		if (allocateLocal == null) throw "Scalar Wasm results require function locals";
		scalarResultTypes.set(output.id, types);
		scalarResults.set(output.id, [for (type in types) allocateLocal(valueType(type))]);
	}

	function physicalFields(name:String):Array<IrObjectField> {
		for (object in layout.program.objects) if (object.name == name) return object.fields;
		throw 'Unknown scalar value "$name"';
	}

	public function scalarLocal(instruction:IrInstruction, locals:Map<Int, Int>):Null<Array<WasmInstruction>> {
		if (scalarLocals == null) return null;
		return switch instruction {
			case NewObject(out, _):
				var candidate = scalarLocals.get(out);
				if (candidate == null) null; else {
					var body:Array<WasmInstruction> = [];
					for (field in candidate.declarations) {
						for (item in zeroValue(field.type)) body.push(item);
						body.push(LocalSet(requiredScalarField(candidate.fields, field.name)));
					}
					body;
				}
			case FieldGet(out, owner, name):
				var candidate = scalarLocals.get(owner);
				if (candidate == null) null;
				else if (name == compiler.backend.wasm.WasmFlattenValueFields.CHECK_FIELD) [];
				else [LocalGet(requiredScalarField(candidate.fields, name)), LocalSet(requiredScalarValue(locals, out.id))];
			case FieldSet(owner, name, value):
				var candidate = scalarLocals.get(owner);
				if (candidate == null) null; else {
					var body:Array<WasmInstruction> = [LocalGet(requiredScalarValue(locals, value.id))], field:Null<IrObjectField> = null;
					for (item in candidate.declarations) if (item.name == name) field = item;
					if (field == null) throw 'Missing scalar field "$name"';
					appendScalarNarrowing(body, field);
					body.push(LocalSet(requiredScalarField(candidate.fields, name))); body;
				}
			default: null;
		};
	}

	static function requiredScalarField(fields:Map<String, Int>, name:String):Int {
		var local = fields.get(name);
		if (local == null) throw 'Missing scalar field "$name"';
		return local;
	}

	static function requiredScalarValue(locals:Map<Int, Int>, id:Int):Int {
		var local = locals.get(id);
		if (local == null) throw 'Missing scalar value $id';
		return local;
	}

	/** The scalar fields replace an object root and follow the original value's liveness. */
	public function scalarReferenceLocals():Map<Int, Array<Int>> {
		var result:Map<Int, Array<Int>> = [];
		if (scalarLocals == null) return result;
		for (id => candidate in scalarLocals.all()) {
			var references:Array<Int> = [];
			for (field in candidate.declarations) if (compiler.backend.wasm.WasmTarget.isReference(field.type)) {
				var local = candidate.fields.get(field.name);
				if (local == null) throw 'Missing scalar reference field "${field.name}"';
				references.push(local);
			}
			result.set(id, references);
		}
		for (id => types in scalarResultTypes) {
			var locals = scalarResults.get(id), references:Array<Int> = [];
			for (index in 0...types.length) if (compiler.backend.wasm.WasmTarget.isReference(types[index])) references.push(locals[index]);
			result.set(id, references);
		}
		return result;
	}

	static function appendScalarNarrowing(body:Array<WasmInstruction>, field:IrObjectField):Void {
		var native = field.nativeLayout, storage = field.scalarStorage;
		if ((switch (field.type) { case F32: true; default: false; }) && (native != null || storage != null)) { body.push(F32DemoteF64); body.push(F64PromoteF32); return; }
		var size = native != null ? native.size : storage != null ? storage.size : 0,
			signed = native != null ? native.signed : storage != null && storage.signed,
			bits = switch field.type { case I32: 32; case I64: 64; default: 0; };
		if (bits > 0 && size > 0 && size * 8 < bits) {
			var shift = bits - size * 8;
			body.push(bits == 64 ? I64Const(shift) : I32Const(shift)); body.push(bits == 64 ? I64Shl : I32Shl);
			body.push(bits == 64 ? I64Const(shift) : I32Const(shift));
			body.push(bits == 64 ? (signed ? I64ShrS : I64ShrU) : (signed ? I32ShrS : I32ShrU));
		}
	}

	public function valueType(type:IrType):WasmValueType
		return WasmModuleSupport.requireValueType(type);

	public function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case I64: [I64Const(0)];
			case F32 | F64: [F64Const(0)];
			case Void: [];
			default: [I32Const(0)];
		};

	public function nullValue(type:IrType, destination:Int):Array<WasmInstruction>
		return [I32Const(0), LocalSet(destination)];

	public function constantString(value:String, destination:Int, strings:Map<String, Int>):WasmLoweringResult
		return UseDefault;

	public function newObject(typeName:String, destination:Int):Array<WasmInstruction> {
		var object = layout.object(typeName),
			nativeLayout = object.nativeLayout,
			body:Array<WasmInstruction> = [I32Const(layout.object(typeName).size), Call(allocator), LocalSet(destination)];
		if (nativeLayout != null)
			body = body.concat([
				LocalGet(destination),
				I32Const(0),
				I32Const(nativeLayout.size + WasmLayout.FLAT_HEADER_SIZE),
				MemoryFill
			]);
		body = body.concat([
			LocalGet(destination),
			I32Const(layout.runtimeTypeIds.id(Obj(typeName))),
			I32Store(0)
		]);
		return body;
	}

	public function fieldGet(object:IrValue, fieldName:String, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		if (StringTools.startsWith(fieldName, WasmScalarAbi.RESULT_FIELD_PREFIX)) {
			var index = Std.parseInt(fieldName.substr(WasmScalarAbi.RESULT_FIELD_PREFIX.length)), results = scalarResults.get(object.id);
			if (index == null || results == null || index < 0 || index >= results.length)
				throw 'Missing scalar Wasm call result $fieldName';
			return [LocalGet(results[index]), LocalSet(destination)];
		}
		if (fieldName == compiler.backend.wasm.WasmFlattenValueFields.CHECK_FIELD)
			return [LocalGet(objectLocal), I32Load(0), LocalSet(destination)];
		var field = objectField(object, fieldName);
		if (field.nativeLayout != null) {
			if (field.nativeLayout.inlineRecord)
				return inlineRecordGet(field, destination, objectLocal);
			return nativeFieldGet(field, destination, objectLocal);
		}
		if (field.scalarStorage != null) {
			var storage = field.scalarStorage, read:Array<WasmInstruction> = [];
			if (((switch (field.type) { case I32: true; default: false; }) || (switch (field.type) { case Bool: true; default: false; })) && storage.size == 1)
				read = [storage.signed ? I32Load8S(field.offset) : I32Load8U(field.offset)];
			else if ((switch (field.type) { case I32: true; default: false; }) && storage.size == 2)
				read = [storage.signed ? I32Load16S(field.offset) : I32Load16U(field.offset)];
			else if ((switch (field.type) { case I64: true; default: false; }) && storage.size == 4)
				read = [I32Load(field.offset), storage.signed ? I64ExtendI32S : I64ExtendI32U];
			else if ((switch (field.type) { case F32: true; default: false; }) && storage.size == 4)
				read = [F32Load(field.offset), F64PromoteF32];
			else read = [load(field.type, field.offset)];
			return [LocalGet(objectLocal)].concat(read).concat([LocalSet(destination)]);
		}
		return [LocalGet(objectLocal), load(field.type, field.offset), LocalSet(destination)];
	}

	public function hasScalarCall(name:String):Bool return scalarAbi != null && scalarAbi.signatures.exists(name);
	public function hasScalarClosure(type:IrType):Bool return scalarAbi != null && scalarAbi.scalarClosures.exists(Std.string(type));

	public function scalarClosureCall(type:IrType, staticType:Int, instanceType:Int, closureLocal:Int, output:IrValue,
			outputLocal:Int, argumentLocals:Array<Int>):Array<WasmInstruction> {
		var abi = scalarAbi;
		if (abi == null) throw "Missing scalar ABI";
		var results:Array<Int> = [];
		if (abi.isValue(output.type)) {
			var stored = scalarResults.get(output.id);
			if (stored == null) throw "Missing scalar closure result locals";
			results = stored;
		} else if ((switch (output.type) { case Void: false; default: true; })) results.push(outputLocal);
		var body:Array<WasmInstruction> = [LocalGet(closureLocal), I32Const(1), I32And, If(null)];
		for (local in argumentLocals) body.push(LocalGet(local));
		body = body.concat([LocalGet(closureLocal), I32Const(-2), I32And, I32Load(WasmLayout.STATIC_CLOSURE_FUNCTION_OFFSET), CallIndirect(staticType)]);
		var index = results.length - 1;
		while (index >= 0) { body.push(LocalSet(results[index])); index--; }
		body = body.concat([Else, LocalGet(closureLocal), I32Load(WasmLayout.CLOSURE_RECEIVER_OFFSET)]);
		for (local in argumentLocals) body.push(LocalGet(local));
		body = body.concat([LocalGet(closureLocal), I32Load(WasmLayout.CLOSURE_FUNCTION_OFFSET), CallIndirect(instanceType)]);
		index = results.length - 1;
		while (index >= 0) { body.push(LocalSet(results[index])); index--; }
		body.push(End);
		return body;
	}
	public function scalarSignature(name:String):Null<compiler.backend.wasm.WasmScalarAbi.WasmScalarSignature>
		return scalarAbi == null ? null : scalarAbi.signatures.get(name);
	public function scalarReturnTypes(signature:compiler.backend.wasm.WasmScalarAbi.WasmScalarSignature):Array<IrType> {
		var abi = scalarAbi;
		if (abi == null) throw "Missing scalar ABI";
		return abi.resultTypes(signature);
	}

	public function scalarExceptionResult(fn:IrFunction, locals:Map<Int, Int>, exception:Int):Array<WasmInstruction> {
		var abi = scalarAbi, signature = scalarSignature(fn.name);
		if (abi == null) throw "Missing scalar ABI";
		if (signature == null || !signature.throwsReceiver || allocateLocal == null) throw 'Invalid scalar exception return "${fn.name}"';
		var receiver:Null<IrValue> = null;
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, _) if (out.id == signature.receiverId): receiver = out;
			default:
		}
		if (receiver == null) throw 'Scalar method "${fn.name}" has no receiver state';
		var name = switch receiver.type { case Obj(value): value; default: throw "Invalid scalar receiver"; },
			candidate = scalarLocals == null ? null : scalarLocals.get(receiver), result:Array<WasmInstruction> = [];
		for (field in physicalFields(name)) {
			if (candidate != null) result.push(LocalGet(requiredScalarField(candidate.fields, field.name)));
			else {
				var local = allocateLocal(valueType(field.type));
				for (instruction in fieldGet(receiver, field.name, local, requiredScalarValue(locals, receiver.id))) result.push(instruction);
				result.push(LocalGet(local));
			}
		}
		if ((switch (signature.result) { case Void: false; default: true; })) for (type in abi.valueTypes(signature.result))
			for (instruction in zeroValue(type)) result.push(instruction);
		result.push(LocalGet(exception)); result.push(I32Const(1));
		return result;
	}

	/** Preserve an inline receiver's writes when its method throws across the scalar ABI. */
	public function scalarExceptionWrapper(fn:IrFunction, body:Array<WasmInstruction>, locals:Map<Int, Int>, tag:Null<Int>,
			cleanup:Array<WasmInstruction>):Null<Array<WasmInstruction>> {
		if (scalarAbi == null) return null;
		var signature = scalarAbi.signatures.get(fn.name);
		if (signature == null || !signature.throwsReceiver) return null;
		if (tag == null) return null;
		if (allocateLocal == null) throw 'Scalar method "${fn.name}" requires function locals';
		var exception = allocateLocal(valueType(Dyn)),
			result:Array<WasmInstruction> = [Try(null)];
		for (instruction in body) result.push(instruction);
		result.push(Catch(tag)); result.push(LocalSet(exception));
		for (instruction in cleanup) result.push(instruction);
		for (instruction in scalarExceptionResult(fn, locals, exception)) result.push(instruction);
		result.push(Return); result.push(End); result.push(Unreachable);
		return result;
	}

	public function scalarCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>,
			functionIndex:Int):Array<WasmInstruction> {
		var abi = scalarAbi;
		if (abi == null) throw "Missing scalar ABI";
		var signature = abi.signatures.get(name), body:Array<WasmInstruction> = [for (local in argumentLocals) LocalGet(local)];
		if (signature == null || allocateLocal == null) throw 'Missing scalar call signature "$name"';
		body.push(Call(functionIndex));
		if (signature.mutatesReceiver || abi.isValue(signature.result)) {
			var locals = scalarResults.get(output.id);
			if (locals == null) throw 'Missing scalar result locals for "$name"';
			var index = locals.length - 1;
			while (index >= 0) { body.push(LocalSet(locals[index])); index--; }
		} else if ((switch (output.type) { case Void: false; default: true; })) body.push(LocalSet(outputLocal));
		return body;
	}

	public function hasScalarVirtual(receiver:IrType, method:String):Bool
		return scalarAbi != null && scalarAbi.scalarVirtuals.exists(WasmScalarAbi.virtualKey(receiver, method));

	public function scalarVirtualCall(receiver:IrValue, method:String, receiverLocal:Int, output:IrValue, outputLocal:Int,
			arguments:Array<IrValue>, argumentLocals:Array<Int>):Array<WasmInstruction> {
		var abi = scalarAbi;
		if (abi == null) throw "Missing scalar ABI";
		var virtual = abi.scalarVirtuals.get(WasmScalarAbi.virtualKey(receiver.type, method));
		if (virtual == null || allocateLocal == null || functions == null) throw 'Missing scalar virtual method "$method"';
		var results:Array<Int> = [];
		if (abi.isValue(virtual.signature.result)) {
			results = scalarResults.get(output.id);
			if (results == null) throw 'Missing scalar virtual result locals for "$method"';
		} else if ((switch (virtual.signature.result) { case Void: false; default: true; })) results.push(outputLocal);
		var body:Array<WasmInstruction> = [];
		for (index in 0...virtual.targets.length) {
			var target = virtual.targets[index], functionIndex = functions.get(target.clone);
			if (functionIndex == null) throw 'Missing scalar virtual target "${target.clone}"';
			body.push(LocalGet(receiverLocal)); body.push(I32Load(0)); body.push(I32Const(layout.runtimeTypeIds.id(Obj(target.typeName))));
			body.push(I32Eq); body.push(If(null)); body.push(LocalGet(receiverLocal));
			for (local in argumentLocals) body.push(LocalGet(local));
			body.push(Call(functionIndex));
			var resultIndex = results.length - 1;
			while (resultIndex >= 0) { body.push(LocalSet(results[resultIndex])); resultIndex--; }
			body.push(Else);
		}
		body.push(Unreachable);
		for (_ in virtual.targets) body.push(End);
		return body;
	}

	public function fieldSet(object:IrValue, fieldName:String, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var field = objectField(object, fieldName);
		if (field.nativeLayout != null) {
			if (field.nativeLayout.inlineRecord)
				return inlineRecordSet(field, objectLocal, valueLocal);
			return nativeFieldSet(field, objectLocal, valueLocal);
		}
		var valueName = switch field.type { case Obj(name) if (valueObjects.exists(name)): name; default: null; };
		if (valueName != null)
			return assignValueField([LocalGet(objectLocal)], field.offset, [LocalGet(valueLocal)], valueName, []);
		var body:Array<WasmInstruction> = [LocalGet(objectLocal), LocalGet(valueLocal)], scalar = field.scalarStorage;
		if (scalar != null) {
			if (((switch (field.type) { case I32: true; default: false; }) || (switch (field.type) { case Bool: true; default: false; })) && scalar.size == 1) {
				body.push(I32Store8(field.offset)); return body;
			} else if ((switch (field.type) { case I32: true; default: false; }) && scalar.size == 2) {
				body.push(I32Store16(field.offset)); return body;
			} else if ((switch (field.type) { case I64: true; default: false; }) && scalar.size == 4) {
				body.push(I32WrapI64); body.push(I32Store(field.offset)); return body;
			} else if ((switch (field.type) { case F32: true; default: false; }) && scalar.size == 4) {
				body.push(F32DemoteF64); body.push(F32Store(field.offset)); return body;
			}
		}
		body.push(store(field.type, field.offset));
		return body;
	}

	/** Keep each embedded value place stable when a whole value is assigned to its field. */
	function assignValueField(parent:Array<WasmInstruction>, offset:Int, source:Array<WasmInstruction>, name:String,
			visiting:Array<String>):Array<WasmInstruction> {
		if (visiting.indexOf(name) >= 0) throw 'Cyclic inline Wasm value "$name"';
		var destination = parent.concat([I32Load(offset)]), result = destination.concat([I32Eqz]);
		// A zero source is an uninitialized value. Keep the existing null representation.
		result = result.concat(source).concat([I32Eqz, I32Or, If(null)]);
		result = result.concat(parent).concat(source).concat([I32Store(offset), Else]);
		var next = visiting.concat([name]);
		for (field in layout.object(name).fields) {
			var childName = switch field.type { case Obj(child) if (valueObjects.exists(child)): child; default: null; };
			if (childName != null) result = result.concat(assignValueField(destination, field.offset,
				source.concat([I32Load(field.offset)]), childName, next));
			else result = result.concat(destination).concat(source).concat([load(field.type, field.offset), store(field.type, field.offset)]);
		}
		result.push(End);
		return result;
	}

	function nativeFieldGet(field:WasmFieldLayout, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Flat Wasm field "${field.name}" is missing layout metadata';
		var body = flatFieldBase(objectLocal, native.offset),
			load:Array<WasmInstruction> = [];
		if ((switch (field.type) { case I32: true; default: false; }) && native.size == 1)
			load = [native.signed ? I32Load8S(0) : I32Load8U(0)];
		else if ((switch (field.type) { case Bool: true; default: false; }) && native.size == 1)
			load = [I32Load8U(0)];
		else if ((switch (field.type) { case I32: true; default: false; }) && native.size == 2)
			load = [native.signed ? I32Load16S(0) : I32Load16U(0)];
		else if ((switch (field.type) { case I64: true; default: false; }) && native.size == 4)
			load = [I32Load(0), native.signed ? I64ExtendI32S : I64ExtendI32U];
		else if ((switch (field.type) { case F32: true; default: false; }) && native.size == 4)
			load = [F32Load(0), F64PromoteF32];
		else if (((switch (field.type) { case I32: true; default: false; }) || (switch (field.type) { case Bool: true; default: false; }) || (switch (field.type) { case RawPtr: true; default: false; })) && native.size == 4)
			load = [I32Load(0)];
		else if ((switch (field.type) { case I64: true; default: false; }) && native.size == 8)
			load = [I64Load(0)];
		else if ((switch (field.type) { case F64: true; default: false; }) && native.size == 8)
			load = [F64Load(0)];
		else
			throw 'Unsupported flat Wasm field storage ${native.size} bytes for ${Std.string(field.type)}';
		return body.concat(load).concat([LocalSet(destination)]);
	}

	function nativeFieldSet(field:WasmFieldLayout, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Flat Wasm field "${field.name}" is missing layout metadata';
		var body:Array<WasmInstruction> = flatFieldBase(objectLocal, native.offset).concat([LocalGet(valueLocal)]);
		if (((switch (field.type) { case I32: true; default: false; }) || (switch (field.type) { case Bool: true; default: false; })) && native.size == 1)
			body.push(I32Store8(0));
		else if ((switch (field.type) { case I32: true; default: false; }) && native.size == 2)
			body.push(I32Store16(0));
		else if ((switch (field.type) { case I64: true; default: false; }) && native.size == 4)
			body = body.concat([I32WrapI64, I32Store(0)]);
		else if ((switch (field.type) { case F32: true; default: false; }) && native.size == 4)
			body = body.concat([F32DemoteF64, F32Store(0)]);
		else if (((switch (field.type) { case I32: true; default: false; }) || (switch (field.type) { case Bool: true; default: false; }) || (switch (field.type) { case RawPtr: true; default: false; })) && native.size == 4)
			body.push(I32Store(0));
		else if ((switch (field.type) { case I64: true; default: false; }) && native.size == 8)
			body.push(I64Store(0));
		else if ((switch (field.type) { case F64: true; default: false; }) && native.size == 8)
			body.push(F64Store(0));
		else
			throw 'Unsupported flat Wasm field storage ${native.size} bytes for ${Std.string(field.type)}';
		return body;
	}

	function inlineRecordGet(field:WasmFieldLayout, destination:Int, objectLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Inline flat Wasm field "${field.name}" is missing layout metadata';
		var childName = switch field.type {
			case Obj(name): name;
			case _: throw 'Inline flat Wasm field "${field.name}" is not a source struct';
		};
		var body = newObject(childName, destination);
		body.push(LocalGet(destination));
		body = body.concat(flatViewOwner(objectLocal));
		body.push(I32Store(4));
		body.push(LocalGet(destination));
		body = body.concat(flatViewOffset(objectLocal, native.offset));
		body.push(I32Store(8));
		return body;
	}

	function inlineRecordSet(field:WasmFieldLayout, objectLocal:Int, valueLocal:Int):Array<WasmInstruction> {
		var native = field.nativeLayout;
		if (native == null)
			throw 'Inline flat Wasm field "${field.name}" is missing layout metadata';
		var body:Array<WasmInstruction> = [];
		for (offset in 0...native.size) {
			body = body.concat(flatFieldBase(objectLocal, native.offset));
			body = body.concat(flatFieldBase(valueLocal, 0));
			body = body.concat([I32Load8U(offset), I32Store8(offset)]);
		}
		return body;
	}

	function flatFieldBase(objectLocal:Int, fieldOffset:Int):Array<WasmInstruction> {
		return [
			LocalGet(objectLocal),
			I32Load(4),
			If(I32),
			LocalGet(objectLocal),
			I32Load(4),
			LocalGet(objectLocal),
			I32Load(8),
			I32Add,
			Else,
			LocalGet(objectLocal),
			End,
			I32Const(WasmLayout.FLAT_HEADER_SIZE),
			I32Add,
			I32Const(fieldOffset),
			I32Add
		];
	}

	function flatViewOwner(objectLocal:Int):Array<WasmInstruction> {
		return [
			LocalGet(objectLocal),
			I32Load(4),
			If(I32),
			LocalGet(objectLocal),
			I32Load(4),
			Else,
			LocalGet(objectLocal),
			End
		];
	}

	function flatViewOffset(objectLocal:Int, fieldOffset:Int):Array<WasmInstruction> {
		return [
			LocalGet(objectLocal),
			I32Load(4),
			If(I32),
			LocalGet(objectLocal),
			I32Load(8),
			Else,
			I32Const(0),
			End,
			I32Const(fieldOffset),
			I32Add
		];
	}

	public function toDynamic(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function safeCast(output:IrValue, value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function toVirtual(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function equal(output:Int, left:IrValue, right:IrValue, leftLocal:Int, rightLocal:Int):Array<WasmInstruction> {
		var instruction = switch left.type {
			case I64: I64Eq;
			case F32 | F64: F64Eq;
			default: I32Eq;
		};
		return [LocalGet(leftLocal), LocalGet(rightLocal), instruction, LocalSet(output)];
	}

	public function dynamicEqual(output:Int, leftLocal:Int, rightLocal:Int):WasmLoweringResult
		return UseDefault;

	public function lowerRuntimeCall(name:String, output:IrValue, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>):WasmLoweringResult {
		if (name == "__int64_to_float") {
			if ((switch (output.type) { case F64: false; default: true; }) || arguments.length != 1 || (switch (arguments[0].type) { case I64: false; default: true; }) || argumentLocals.length != 1)
				throw "Invalid Wasm Int64.toFloat signature";
			return [LocalGet(argumentLocals[0]), F64ConvertI64S, LocalSet(outputLocal)];
		}
		if (name == "__wasm_memory_load_i32") {
			if ((switch (output.type) { case I32: false; default: true; }) || arguments.length != 1 || (switch (arguments[0].type) { case I32: false; default: true; }) || argumentLocals.length != 1)
				throw "Invalid Wasm runtime memory.load i32 signature";
			return [LocalGet(argumentLocals[0]), I32Load(0), LocalSet(outputLocal)];
		}
		if (name == "__f32_to_i32_bits") {
			if (!compiler.ir.IrVerifier.sameType(output.type, I32) || arguments.length != 1
				|| !compiler.ir.IrVerifier.sameType(arguments[0].type, F32) || argumentLocals.length != 1)
				throw "Invalid Wasm Float32 bit conversion signature";
			return [LocalGet(argumentLocals[0]), F32DemoteF64, I32ReinterpretF32, LocalSet(outputLocal)];
		}
		if (name == "__i32_to_f32_bits") {
			if (!compiler.ir.IrVerifier.sameType(output.type, F32) || arguments.length != 1
				|| !compiler.ir.IrVerifier.sameType(arguments[0].type, I32) || argumentLocals.length != 1)
				throw "Invalid Wasm Float32 bit conversion signature";
			return [LocalGet(argumentLocals[0]), F32ReinterpretI32, F64PromoteF32, LocalSet(outputLocal)];
		}
		if (name == "__f64_to_i64_bits" || name == "runtime.FloatBits.toInt64") {
			if ((switch (output.type) { case I64: false; default: true; }) || arguments.length != 1 || (switch (arguments[0].type) { case F64: false; default: true; }) || argumentLocals.length != 1)
				throw "Invalid Wasm FloatBits.toInt64 signature";
			return [LocalGet(argumentLocals[0]), I64ReinterpretF64, LocalSet(outputLocal)];
		}
		if (name == "__i64_to_f64_bits" || name == "runtime.FloatBits.fromInt64") {
			if ((switch (output.type) { case F64: false; default: true; }) || arguments.length != 1 || (switch (arguments[0].type) { case I64: false; default: true; }) || argumentLocals.length != 1)
				throw "Invalid Wasm FloatBits.fromInt64 signature";
			return [LocalGet(argumentLocals[0]), F64ReinterpretI64, LocalSet(outputLocal)];
		}
		return UseDefault;
	}

	public function lowerCNativeCall(native:IrCNative, arguments:Array<IrValue>, outputLocal:Int, argumentLocals:Array<Int>, importIndex:Int,
			pointerLengthImportIndex:Int, pointerReleaseImportIndex:Int):WasmLoweringResult {
		var abi = WasmCAbi.of(native), fixed = native.fixedResult;
		if (!abi.adjustsCall() && (switch (native.result) { case Bytes: false; default: true; }))
			return UseDefault;
		var body:Array<WasmInstruction> = [];
		if (fixed == null) {
			pushNativeArguments(body, abi, arguments, argumentLocals);
			body.push(Call(importIndex));
			body = body.concat(abi.raiseResult());
			if ((switch (native.result) { case Bytes: true; default: false; }))
				body.push(Call(cstringCopy));
			if (outputLocal >= 0)
				body.push(LocalSet(outputLocal));
			return body;
		}
		if ((switch (native.result) { case ManagedBytes: false; default: true; }) || outputLocal < 0)
			throw 'Linear Wasm C native "${native.name}" has an invalid fixed aggregate result contract';
		var allocationSize = WasmLayout.STRING_DATA_OFFSET + fixed.size;
		// The record result lands in a managed Bytes value that the generated HXI wrapper then attaches the
		// projected fixed-layout record to. The native either returns its single scalar, stored here, or
		// writes the record through the pointer it receives first.
		body.push(I32Const(allocationSize));
		body.push(Call(allocator));
		body.push(LocalSet(outputLocal));
		for (field in [
			{offset: 0, value: layout.runtimeTypeIds.id(ManagedBytes)},
			{offset: WasmLayout.STRING_LENGTH_OFFSET, value: fixed.size},
			{offset: WasmLayout.ARRAY_CAPACITY_OFFSET, value: fixed.size}
		]) {
			body.push(LocalGet(outputLocal));
			body.push(I32Const(field.value));
			body.push(I32Store(field.offset));
		}
		body.push(LocalGet(outputLocal));
		body.push(I32Const(WasmLayout.STRING_DATA_OFFSET));
		body.push(I32Add);
		pushNativeArguments(body, abi, arguments, argumentLocals);
		body.push(Call(importIndex));
		if (abi.directResult != null)
			body.push(abi.directResult.store);
		return body;
	}

	function pushNativeArguments(body:Array<WasmInstruction>, abi:WasmCAbi, arguments:Array<IrValue>, argumentLocals:Array<Int>):Void {
		for (index in 0...arguments.length) {
			nativeArgument(body, arguments[index], argumentLocals[index]);
			for (instruction in abi.lowerArgument(index))
				body.push(instruction);
		}
	}

	public function arrayGet(array:IrValue, index:IrValue, destination:Int, arrayLocal:Int, indexLocal:Int):WasmLoweringResult
		return UseDefault;

	public function arraySet(array:IrValue, index:IrValue, value:IrValue, arrayLocal:Int, indexLocal:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function arraySize(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult
		return UseDefault;

	public function iteratorNew(array:IrValue, destination:Int, arrayLocal:Int):WasmLoweringResult
		return UseDefault;

	public function iteratorHasNext(iterator:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult
		return UseDefault;

	public function iteratorNext(iterator:IrValue, output:IrValue, destination:Int, iteratorLocal:Int):WasmLoweringResult
		return UseDefault;

	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>, destination:Int, argumentLocals:Array<Int>):WasmLoweringResult
		return UseDefault;

	public function enumIndex(value:IrValue, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	public function enumField(value:IrValue, constructor:Int, field:Int, destination:Int, valueLocal:Int):WasmLoweringResult
		return UseDefault;

	function objectField(object:IrValue, name:String):WasmFieldLayout {
		return switch object.type {
			case Obj(objectName): layout.field(objectName, name);
			default: throw 'Wasm field access requires an object reference, got ${Std.string(object.type)}';
		};
	}

	static function load(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Load(offset);
			case F32 | F64: F64Load(offset);
			default: I32Load(offset);
		};

	static function store(type:IrType, offset:Int):WasmInstruction
		return switch type {
			case I64: I64Store(offset);
			case F32 | F64: F64Store(offset);
			default: I32Store(offset);
		};

	function nativeArgument(body:Array<WasmInstruction>, argument:IrValue, argumentLocal:Int):Void {
		body.push(LocalGet(argumentLocal));
		switch argument.type {
			case Bytes, ManagedBytes:
				body.push(Call(bytesDataPointer));
			case Abstract("realtime_bytes"):
				body.push(I32Const(WasmLayout.STRING_DATA_OFFSET));
				body.push(I32Add);
			case _:
		}
	}
}
