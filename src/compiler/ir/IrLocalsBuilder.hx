package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrFunction.IrDebugBinding;
import compiler.ir.IrSsaVariables;
import compiler.ir.IrIteratorReplacement.IrIteratorStore;
import compiler.core.Source.SourceSpan;
import compiler.ir.SourceProvenance;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance.SourceOrigin;

/** Source-level identity and lexical range of a local the debugger shows. */
private typedef IrDebugLocal = {
	final identity:String;
	final name:String;
	final span:SourceSpan;
	final scopeEnd:Int;
}

/**
 * Builds a function's SSA blocks from code that reads and writes named locals, while tracking lexical trap scopes. Locals are read and written by name (`load`, `store`)
 * and never become instructions: `IrSsaVariables` gives each read the value that reaches it (`DIRECT_SSA.md`). A block
 * is sealed when it is selected, so every edge into it must exist by then; a block that gets edges later, such as a loop
 * header, is made with `createOpenBlock` and sealed by `seal` or when the function is finished.
 */
class IrLocalsBuilder {
	/** Expressions and statements share the lexical loop targets of this function. */
	@:allow(compiler.ir.IrGenerator)
	final loopContexts:Array<IrLoopContext> = [];

	public final blocks:Array<IrBlock> = [];

	final debugLocals:Map<String, IrDebugLocal> = [];
	final variables:IrSsaVariables;
	final scratch:IrSsaScratch;

	/** Values stored to locals the debugger may show, by variable, bound when the function is finished. */
	final storedVariables:Array<Int> = [];
	final storedValues:Array<IrValue> = [];

	/** Stores of iterators, for `IrIteratorReplacement`. */
	final iteratorStores:Array<IrIteratorStore> = [];

	final argumentVariables:Map<Int, Bool> = [];

	var current:IrBlock;

	/**
	 * The locals that hold evaluated operands are named by number within a function; the first names are made once and shared by all
	 * functions, and a function with more operands makes the rest. The table is never changed, so any thread may read it.
	 */
	static final operandNames:Array<String> = [for (index in 0...OPERAND_NAMES) "$operand:" + index];

	static inline final OPERAND_NAMES = 256;

	var nextOperand:Int = 0;

	/** A local name no other operand of this function uses. */
	public function operandName():String {
		var index = nextOperand++;
		return index < OPERAND_NAMES ? operandNames[index] : "$operand:" + index;
	}

	var activeTraps:Array<{id:Int, preserveExceptionStack:Bool}> = [];
	var provenance:SourceProvenance = SourceProvenance.generated("cfg-builder");

	public function new(scratch:IrSsaScratch, ?localTypes:Map<String, IrType>) {
		this.scratch = scratch;
		variables = new IrSsaVariables(scratch, localTypes);
		current = createBlock();
		select(current);
	}

	/** A block whose predecessors all exist by the time it is selected. */
	public function createBlock():IrBlock
		return addBlock(true);

	/** A block that can get predecessors after it is selected, such as a loop header; see `seal`. */
	public function createOpenBlock():IrBlock
		return addBlock(false);

	function addBlock(sealed:Bool):IrBlock {
		var block = new IrBlock(blocks.length);
		blocks.push(block);
		variables.addBlock(block.id, sealed);
		return block;
	}

	/** Every edge into `block`, made by `createOpenBlock`, now exists. */
	public function seal(block:IrBlock):Void
		variables.seal(block.id);

	public function select(block:IrBlock):Void {
		current = block;
		variables.select(block.id);
	}

	public function currentBlock():IrBlock
		return current;

	/** A function input, defined at entry. Arguments are declared before anything is emitted. */
	public function argument(name:String, type:IrType):IrValue {
		var value = new IrValue(variables.nextValue++, name, type), variable = variables.variable(name, type);
		variables.write(variable, 0, value);
		argumentVariables.set(variable, true);
		noteStore(variable, value);
		return value;
	}

	public function debugLocal(identity:String, span:SourceSpan, scopeEnd:Int):Void {
		if (debugLocals.exists(identity))
			return;
		var name = compiler.ir.DebugNames.sourceLocal(identity);
		if (name == null)
			return;
		debugLocals.set(identity, {
			identity: identity,
			name: name,
			span: span,
			scopeEnd: scopeEnd
		});
	}

	/** Select the source context inherited by subsequently emitted operations. */
	public function at(span:SourceSpan):Void
		provenance = SourceProvenance.user(span);

	/** Select an explicit compiler-generated context, optionally anchored in source. */
	public function generated(reason:String, ?anchor:SourceSpan):Void
		provenance = SourceProvenance.generated(reason, anchor);

	/** Mark what is emitted until `restoreSource` as generated for `reason`, keeping the current source location. */
	public function beginGenerated(reason:String):SourceProvenance {
		var previous = provenance;
		provenance = new SourceProvenance(previous.location, CompilerGenerated(reason));
		return previous;
	}

	/** Enter a nested source context and return the token needed to restore it. */
	public function enterSource(span:SourceSpan):SourceProvenance {
		var previous = provenance;
		provenance = SourceProvenance.user(span);
		return previous;
	}

	/** Restore a context returned by {@link enterSource}. */
	public function restoreSource(previous:SourceProvenance):Void
		provenance = previous;

	public function isTerminated():Bool
		return current.terminator != null;

	public function jump(target:IrBlock):Void
		terminate(Jump(target.id));

	/** Attach a forward edge after both branch bodies have been lowered. */
	public function jumpFrom(source:IrBlock, target:IrBlock):Void {
		if (source.terminator != null)
			throw new InternalError('IR block ${source.id} already has a terminator');
		var anchor = source.instructions.length == 0
			? provenance.location : source.instructions[source.instructions.length - 1].provenance.location;
		source.terminator = new Located(Jump(target.id),
			new SourceProvenance(anchor, SourceOrigin.CompilerGenerated("structured-join")));
		variables.addEdge(source.id, target.id);
	}

	public function branch(condition:IrValue, yes:IrBlock, no:IrBlock):Void
		terminate(Branch(condition, yes.id, no.id));

	/** A dense multiway branch on the Int `value`: to `targets[value]`, or to `otherwise` for any other value. */
	public function switchOn(value:IrValue, targets:Array<IrBlock>, otherwise:IrBlock):Void
		terminate(Switch(value, [for (target in targets) target.id], otherwise.id));

	public function returnValue(value:IrValue):Void
		terminate(Return(value));

	public function returnVoid():Void {
		var out = temporary(Void);
		emit(ConstVoid(out));
		terminate(Return(out));
	}

	public function constVoid():IrValue {
		var out = temporary(Void);
		emit(ConstVoid(out));
		return out;
	}

	public function throwValue(value:IrValue):Void
		terminate(Throw(value));

	public function rethrowValue(value:IrValue):Void
		terminate(Rethrow(value));

	/** Seal a block that is unreachable from the function entry. */
	public function markUnreachable():Void {
		if (isTerminated())
			return;
		generated("unreachable-block");
		throwValue(toDyn(constString("Reached compiler-generated unreachable block")));
	}

	public function beginTry(catchBlock:IrBlock, afterBlock:IrBlock, preserveExceptionStack:Bool = false):Void {
		emit(BeginTry(catchBlock.id, afterBlock.id, preserveExceptionStack));
		// The handler sees the locals as they are here: the protected body starts a block of its own.
		variables.addEdge(current.id, catchBlock.id);
		activeTraps.push({id: catchBlock.id, preserveExceptionStack: preserveExceptionStack});
		// Handler state belongs to trap entry, never to definitions after a call
		// that can throw. Keep the protected body in a separate basic block.
		var protectedBody = createBlock();
		jump(protectedBody);
		select(protectedBody);
	}

	public function endTry():Void {
		var trap = activeTraps.pop();
		if (trap == null)
			throw new InternalError("No active try block");
		emit(EndTry(trap.id, trap.preserveExceptionStack));
	}

	/** Forget a trap after all paths in the current block have terminated. */
	public function discardTry():Void {
		if (activeTraps.length == 0)
			throw new InternalError("No active try block");
		activeTraps.pop();
	}

	/** Close traps on a terminating path without changing the lexical stack. */
	public function closeTrapsForExit():Void
		closeTrapsToDepth(0);

	public function trapDepth():Int
		return activeTraps.length;

	/** Close traps opened inside a destination scope without mutating lexical state. */
	public function closeTrapsToDepth(depth:Int):Void {
		closeTrapsBetween(activeTraps.length, depth);
	}

	/** Close a portion of the lexical trap stack on a single exit edge. */
	public function closeTrapsBetween(from:Int, depth:Int):Void {
		if (depth < 0 || depth > from || from > activeTraps.length)
			throw new InternalError('Invalid trap depth $depth');
		var index = from;
		while (index > depth) {
			index--;
			var trap = activeTraps[index];
			emit(EndTry(trap.id, trap.preserveExceptionStack));
		}
	}

	public function catchValue():IrValue {
		var out = temporary(Dyn);
		emit(Catch(out));
		return out;
	}

	public function safeCast(value:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(SafeCast(out, value));
		return out;
	}

	public function intToFloat(value:IrValue):IrValue {
		var out = temporary(F64);
		emit(IntToFloat(out, value));
		return out;
	}

	public function intToInt64(value:IrValue):IrValue {
		var out = temporary(I64);
		emit(IntToInt64(out, value));
		return out;
	}

	public function floatToInt(value:IrValue):IrValue {
		var out = temporary(I32);
		emit(FloatToInt(out, value));
		return out;
	}

	public function floatToFloat(value:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(FloatToFloat(out, value));
		return out;
	}

	public function typeValue(type:IrType):IrValue {
		var out = temporary(TypeRef);
		emit(TypeValue(out, type));
		return out;
	}

	/** The value of local `name` here. */
	public function load(name:String, type:IrType):IrValue {
		if (isTerminated())
			throw new InternalError("Cannot emit after IR terminator");
		return variables.read(variables.variable(name, type), current.id);
	}

	/** Makes `value` the value of local `name` from here on. */
	public function store(name:String, value:IrValue):Void {
		if (isTerminated())
			throw new InternalError("Cannot emit after IR terminator");
		var variable = variables.variable(name, value.type);
		variables.write(variable, current.id, value);
		noteStore(variable, value);
		switch value.type {
			case Iterator(_):
				iteratorStores.push({
					variable: variable,
					value: value,
					block: current.id,
					index: current.instructions.length
				});
			default:
		}
	}

	/** Stores to locals the debugger may show are bound once the function is finished, when all such locals are known. */
	function noteStore(variable:Int, value:IrValue):Void {
		while (shown.length <= variable)
			shown.push(0);
		var known = shown[variable];
		if (known == 0) {
			known = compiler.ir.DebugNames.sourceLocal(variables.variableName(variable)) == null ? 2 : 1;
			shown[variable] = known;
		}
		if (known == 1) {
			storedVariables.push(variable);
			storedValues.push(value);
		}
	}

	/** Per variable: 0 not asked yet, 1 a name the debugger may show, 2 one it never shows. */
	final shown:Array<Int> = [];

	/**
	 * Seals what is still open, places the phis and empties the blocks no path reaches. The debug bindings are the stores
	 * and phis of the locals declared with `debugLocal`.
	 */
	public function finish():{blocks:Array<IrBlock>, debugBindings:Array<IrDebugBinding>, valueCount:Int} {
		variables.sealAll();
		var replaced = IrIteratorReplacement.run(blocks, variables, iteratorStores,
			variable -> argumentVariables.exists(variable));
		var bindings:Array<IrDebugBinding> = [];
		for (index in 0...storedVariables.length)
			if (replaced.indexOf(storedVariables[index]) < 0)
				bind(bindings, storedVariables[index], variables.find(storedValues[index]));
		variables.finish(blocks, (variable, value) -> bind(bindings, variable, value));
		return {blocks: blocks, debugBindings: bindings, valueCount: variables.nextValue};
	}

	function bind(bindings:Array<IrDebugBinding>, variable:Int, value:IrValue):Void {
		var local = debugLocals.get(variables.variableName(variable));
		if (local != null && value.id >= 0)
			bindings.push({
				identity: local.identity,
				name: local.name,
				value: value,
				path: local.span.file.path,
				scopeStart: local.span.start,
				scopeEnd: local.scopeEnd
			});
	}

	public function globalGet(name:String, type:IrType):IrValue {
		var out = temporary(type);
		emit(GlobalGet(out, name));
		return out;
	}

	public function globalSet(name:String, value:IrValue):Void
		emit(GlobalSet(name, value));

	public function constInt(value:Int, type:IrType = I32):IrValue {
		var out = temporary(type);
		emit(ConstInt(out, value));
		return out;
	}

	public function constFloat(value:Float, type:IrType = F64):IrValue {
		var out = temporary(type);
		emit(ConstFloat(out, value));
		return out;
	}

	public function constString(value:String):IrValue {
		var out = temporary(Bytes);
		emit(ConstString(out, value));
		return out;
	}

	public function staticDataAddress(bytes:Array<Int>):IrValue {
		var out = temporary(I32);
		emit(StaticDataAddress(out, bytes));
		return out;
	}

	public function pointerOffset(pointer:IrValue, byteOffset:IrValue):IrValue {
		var out = temporary(RawPtr);
		emit(PointerOffset(out, pointer, byteOffset));
		return out;
	}

	public function memoryLoad(pointer:IrValue, type:IrType, size:Int, signed:Bool):IrValue {
		var out = temporary(type);
		emit(MemoryLoad(out, pointer, size, signed));
		return out;
	}

	public function memoryStore(pointer:IrValue, value:IrValue, size:Int):Void
		emit(MemoryStore(pointer, value, size));

	public function constBool(value:Bool):IrValue {
		var out = temporary(Bool);
		emit(ConstBool(out, value));
		return out;
	}

	public function constNull(type:IrType):IrValue {
		var out = temporary(type);
		emit(ConstNull(out));
		return out;
	}

	/** Boxes the value. `target` is `Dyn` by default, or `Nullable` of the value's own type to keep the primitive on record. */
	public function toDyn(value:IrValue, ?target:IrType):IrValue {
		if ((switch (value.type) {
			case Dyn: true;
			default: false;
		}) && target == null)
			return value;
		var out = temporary(target == null ? Dyn : target);
		emit(ToDyn(out, value));
		return out;
	}

	public function add(a, b):IrValue
		return binary(a, b, 0);

	public function sub(a, b):IrValue
		return binary(a, b, 1);

	public function mul(a, b):IrValue
		return binary(a, b, 2);

	public function div(a, b):IrValue
		return binary(a, b, 3);

	public function mod(a, b):IrValue
		return binary(a, b, 7);

	public function bitAnd(a, b):IrValue
		return binary(a, b, 8);

	public function bitXor(a, b):IrValue
		return binary(a, b, 9);

	public function bitOr(a, b):IrValue
		return binary(a, b, 10);

	public function shiftLeft(a, b):IrValue
		return binary(a, b, 11);

	public function shiftRight(a, b):IrValue
		return binary(a, b, 12);

	public function unsignedShiftRight(a, b):IrValue
		return binary(a, b, 13);

	public function less(a, b):IrValue
		return binary(a, b, 4, Bool);

	public function lessEqual(a, b):IrValue
		return binary(a, b, 5, Bool);

	public function equal(a, b):IrValue
		return binary(a, b, 6, Bool);

	public function call(name:String, args:Array<IrValue>, result:IrType):IrValue {
		var out = temporary(result);
		emit(Call(out, IrSymbol.of(name), args));
		return out;
	}

	public function cNativeCall(name:String, args:Array<IrValue>, result:IrType):IrValue {
		var out = temporary(result);
		emit(CNativeCall(out, name, args));
		return out;
	}

	public function intrinsic(operation:IrIntrinsic, args:Array<IrValue>, result:IrType):IrValue {
		var out = temporary(result);
		emit(Intrinsic(out, operation, args));
		return out;
	}

	public function staticClosure(name:String, type:IrType):IrValue {
		var out = temporary(type);
		emit(StaticClosure(out, IrSymbol.of(name)));
		return out;
	}

	public function callClosure(closure:IrValue, args:Array<IrValue>, result:IrType):IrValue {
		var out = temporary(result);
		emit(CallClosure(out, closure, args));
		return out;
	}

	public function toVirtual(value:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(ToVirtual(out, value));
		return out;
	}

	public function upcast(value:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(Upcast(out, value));
		return out;
	}

	public function methodCall(object:IrValue, methodName:String, args:Array<IrValue>, result:IrType,
			terminalReceiver:Bool = false):IrValue {
		var out = temporary(result);
		emit(MethodCall(out, object, methodName, args, terminalReceiver));
		return out;
	}

	public function instanceClosure(name:String, receiver:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(InstanceClosure(out, IrSymbol.of(name), receiver));
		return out;
	}

	public function valueInit(typeName:String):IrValue {
		var out = temporary(Obj(typeName));
		emit(ValueInit(out));
		return out;
	}

	public function newObject(typeName:String):IrValue {
		var out = temporary(Obj(typeName));
		emit(NewObject(out, typeName));
		return out;
	}

	public function fieldGet(object:IrValue, fieldName:String, type:IrType):IrValue {
		var out = temporary(type);
		emit(FieldGet(out, object, fieldName));
		return out;
	}

	public function fieldSet(object:IrValue, fieldName:String, value:IrValue):Void
		emit(FieldSet(object, fieldName, value));

	public function arrayGet(array:IrValue, index:IrValue, type:IrType):IrValue {
		var out = temporary(type);
		emit(ArrayGet(out, array, index));
		return out;
	}

	public function arraySet(array:IrValue, index:IrValue, value:IrValue):Void
		emit(ArraySet(array, index, value));

	public function arraySize(array:IrValue):IrValue {
		var out = temporary(I32);
		emit(ArraySize(out, array));
		return out;
	}

	public function iteratorNew(array:IrValue):IrValue {
		var element = switch array.type {
			case Array(element): element;
			default: throw new InternalError("Iterator creation requires an Array value");
		};
		var out = temporary(Iterator(element));
		emit(IteratorNew(out, array));
		return out;
	}

	public function iteratorHasNext(iterator:IrValue):IrValue {
		var out = temporary(Bool);
		emit(IteratorHasNext(out, iterator));
		return out;
	}

	public function iteratorNext(iterator:IrValue, elementType:IrType):IrValue {
		var out = temporary(elementType);
		emit(IteratorNext(out, iterator));
		return out;
	}

	public function makeEnum(typeName:String, constructor:Int, arguments:Array<IrValue>):IrValue {
		var out = temporary(Enum(typeName));
		emit(MakeEnum(out, typeName, constructor, arguments));
		return out;
	}

	public function enumIndex(value:IrValue):IrValue {
		var out = temporary(I32);
		emit(EnumIndex(out, value));
		return out;
	}

	public function enumField(value:IrValue, constructor:Int, field:Int, type:IrType):IrValue {
		var out = temporary(type);
		emit(EnumField(out, value, constructor, field));
		return out;
	}

	function binary(a:IrValue, b:IrValue, kind:Int, ?type:IrType):IrValue {
		var out = temporary(type == null ? a.type : type);
		emit(switch kind {
			case 0: Add(out, a, b);
			case 1: Sub(out, a, b);
			case 2: Mul(out, a, b);
			case 3: Div(out, a, b);
			case 7: Mod(out, a, b);
			case 8: BitAnd(out, a, b);
			case 9: BitXor(out, a, b);
			case 10: BitOr(out, a, b);
			case 11: ShiftLeft(out, a, b);
			case 12: ShiftRight(out, a, b);
			case 13: UnsignedShiftRight(out, a, b);
			case 4: Less(out, a, b);
			case 5: LessEqual(out, a, b);
			default: Equal(out, a, b);
		});
		return out;
	}

	function temporary(type:IrType):IrValue {
		var id = variables.nextValue++;
		return new IrValue(id, scratch.valueName(id), type);
	}

	function emit(value:IrInstruction):Void {
		if (isTerminated())
			throw new InternalError("Cannot emit after IR terminator");
		current.instructions.push(new Located(value, provenance));
	}

	function terminate(value:IrTerminator):Void {
		if (isTerminated())
			throw new InternalError('IR block ${current.id} already has a terminator');
		current.terminator = new Located(value, provenance);
		switch value {
			case Jump(target):
				variables.addEdge(current.id, target);
			case Branch(_, yes, no):
				variables.addEdge(current.id, yes);
				variables.addEdge(current.id, no);
			case Switch(_, targets, otherwise):
				for (target in targets)
					variables.addEdge(current.id, target);
				variables.addEdge(current.id, otherwise);
			case Return(_), Throw(_), Rethrow(_), Unreachable:
		}
	}
}
