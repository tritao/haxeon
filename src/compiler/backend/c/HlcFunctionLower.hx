package compiler.backend.c;

import compiler.backend.c.HlcTypes.HlcField;
import compiler.core.InternalError;
import compiler.hl.HlType;
import compiler.hl.incremental.HlSymbolRequest.HlRemap;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBody;
import compiler.ir.IrBodyGraph;
import compiler.ir.IrOpcode;
import compiler.ir.IrPassScratch.IrNonNullScratch;
import compiler.ir.IrPassScratch.IrValueMarks;
import compiler.ir.IrValueId;

/** An IR construct the C backend does not lower yet: the compile stops with what and where (docs/design/AOT_BACKEND.md). */
class HlcUnsupported extends InternalError {}

/**
 * Lowers one function's IR body to C (docs/design/AOT_BACKEND.md). Each SSA value is a C local of its HashLink register type;
 * phis are assigned on the edges into their block; names resolve through the HashLink assembly's symbol table, as `HlLower`
 * resolves them, so both backends agree on every slot, field and type. The receiver null checks, string literals and enum
 * constants follow `HlLower`'s decisions.
 */
class HlcFunctionLower {
	final module:HlcModule;
	final types:HlcTypes;
	final graph = new IrBodyGraph();
	final nonNullScratch = new IrNonNullScratch();

	/** Value places that never escape, kept as one C local per field as `HlLower` keeps them in registers. */
	final scalarLocals = new compiler.hl.lower.HlScalarValueLocals();

	/** The C type of each scalar local, by its number. */
	final scalarLocalTypes:Array<Int> = [];

	var body:IrBody;
	var out:StringBuf;
	var valueTypes:Array<Int> = [];
	var nullValues:Array<Bool> = [];
	var nonNull:IrValueMarks;
	var temporaries = 0;
	var lastLine = -1;
	var lastPath = "";
	var hasTry = false;
	var functionResult = -1;
	final reachable:Array<Bool> = [];

	/** How many operands of the body read each value. */
	final uses:Array<Int> = [];

	/** The `array:index` pairs of Int and Float arrays an access in the block being lowered validated. */
	final validatedAccesses:Map<String, Bool> = [];

	public function new(module:HlcModule) {
		this.module = module;
		this.types = module.types;
	}

	/** Writes the C definition of the function in slot `slot`, whose body is `source`, to `output`. */
	public function lower(source:IrBody, slot:Int, output:StringBuf):Void {
		body = source;
		out = output;
		temporaries = 0;
		lastLine = -1;
		lastPath = "";
		nonNull = compiler.ir.IrNonNullFacts.analyzeBody(body, true, graph.reset(body), nonNullScratch);
		var limit = body.valueLimit();
		valueTypes.resize(0);
		nullValues.resize(0);
		for (_ in 0...limit) {
			valueTypes.push(-1);
			nullValues.push(false);
		}
		markReachable();
		uses.resize(0);
		for (_ in 0...limit)
			uses.push(0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (operand in 0...body.operandCount(row))
					uses[body.operand(row, operand)]++;
				row = body.nextRow(row);
			}
		}
		scalarLocalTypes.resize(0);
		scalarLocals.reset(body, module.view, function(type) {
			scalarLocalTypes.push(HlRemap.typeIndex(module.symbols, type));
			return scalarLocalTypes.length - 1;
		});
		hasTry = false;
		var phis:Map<Int, Bool> = [];
		eachRow(function(block, row) {
			switch body.opcode(row) {
				case IrOpcode.ConstNull:
					nullValues[body.output(row)] = true;
				case IrOpcode.BeginTry:
					hasTry = true;
				case IrOpcode.Phi:
					phis.set(body.output(row), true);
				default:
			}
		});
		var signature = types.signature(module.slotType(slot));
		functionResult = signature.result;
		var arguments = [for (index in 0...body.argumentCount()) body.argument(index)];
		if (arguments.length != signature.arguments.length)
			throw new InternalError('C lowering of ${body.name}: ${arguments.length} arguments for a slot type of ${signature.arguments.length}');
		out.add('${module.prototype(slot, [for (argument in arguments) v(argument)])} {\n');
		var isArgument:Map<Int, Bool> = [];
		for (index in 0...arguments.length)
			isArgument.set(arguments[index], true);
		// Locals assigned after a trap's setjmp and read in its handler are phis in SSA; C keeps them only when volatile.
		var declared:Map<Int, Bool> = [];
		eachRow(function(block, row) {
			var value = body.output(row);
			if (!value.exists() || isArgument.exists(value) || declared.exists(value) || types.isVoid(typeOf(value)))
				return;
			declared.set(value, true);
			var qualifier = hasTry && phis.exists(value) ? " volatile" : "";
			out.add('\t${types.cType(typeOf(value))}$qualifier v$value;\n');
		});
		for (local in 0...scalarLocalTypes.length)
			if (!types.isVoid(scalarLocalTypes[local]))
				out.add('\t${types.cType(scalarLocalTypes[local])}${hasTry ? " volatile" : ""} s$local;\n');
		var traps:Map<Int, Bool> = [];
		eachRow(function(block, row) {
			if (body.opcode(row) == IrOpcode.BeginTry) {
				var catchBlock = body.auxInt(row, 0);
				if (!traps.exists(catchBlock)) {
					traps.set(catchBlock, true);
					out.add(body.auxInt(row, 2) == 1
						? '\thl_cleanup_trap_ctx trap$catchBlock;\n' : '\thl_trap_ctx trap$catchBlock;\n');
				}
			}
		});
		for (block in 0...body.blockCount())
			if (reachable[block])
				lowerBlock(block, traps);
		out.add("}\n\n");
	}

	/** The blocks control reaches from the entry, through branches and traps: as for `HlLower`, the others are not written. */
	function markReachable():Void {
		reachable.resize(0);
		for (_ in 0...body.blockCount())
			reachable.push(false);
		var pending = [0];
		while (pending.length > 0) {
			var block = pending.pop();
			if (reachable[block])
				continue;
			reachable[block] = true;
			var terminator = body.terminatorRow(block), row = body.firstRow(block);
			while (row >= 0 && row != terminator) {
				if (body.opcode(row) == IrOpcode.BeginTry)
					pending.push(body.blockIndex(body.auxInt(row, 0)));
				row = body.nextRow(row);
			}
			if (terminator >= 0)
				for (index in 0...body.successorCount(terminator))
					pending.push(body.blockIndex(body.successor(terminator, index)));
		}
	}

	function eachRow(visit:(block:Int, row:Int) -> Void):Void
		for (block in 0...body.blockCount()) {
			if (!reachable[block])
				continue;
			var row = body.firstRow(block);
			while (row >= 0) {
				visit(block, row);
				row = body.nextRow(row);
			}
		}

	function lowerBlock(block:Int, traps:Map<Int, Bool>):Void {
		var id = body.blockId(block);
		out.add('b$id:;\n');
		validatedAccesses.clear();
		var terminator = body.terminatorRow(block), row = body.firstRow(block);
		if (terminator < 0)
			throw new InternalError('Reachable IR block $id of ${body.name} has no terminator');
		while (row >= 0 && row != terminator) {
			position(row);
			lowerRow(row, traps);
			row = body.nextRow(row);
		}
		position(terminator);
		lowerTerminator(block, terminator);
	}

	/** A `#line` directive when the row's source line differs from the last one written, so C debug info names Haxe lines. */
	function position(row:Int):Void {
		var location = body.provenance(row).location;
		if (location == null || location.line <= 0)
			return;
		if (location.line == lastLine && location.path == lastPath)
			return;
		lastLine = location.line;
		lastPath = location.path;
		out.add('#line ${location.line} ${HlcModule.quote(location.path)}\n');
	}

	inline function line(text:String):Void {
		out.add("\t");
		out.add(text);
		out.add("\n");
	}

	inline function v(value:IrValueId):String
		return "v" + (value:Int);

	/** The HashLink type of `value`, interned the first time it is asked: a value no reachable row defines may name a type the assembly never registered. */
	function typeOf(value:IrValueId):Int {
		var known = valueTypes[value];
		if (known < 0) {
			known = HlRemap.typeIndex(module.symbols, body.valueType(value));
			valueTypes[value] = known;
		}
		return known;
	}

	function unsupported(what:String):HlcUnsupported
		return new HlcUnsupported('C backend: $what in ${body.name}');

	/** `expression`, of type `from`, as a C value of type `to`. */
	function convert(expression:String, from:Int, to:Int):String {
		var fromType = types.cType(from), toType = types.cType(to);
		return fromType == toType ? expression : '(($toType)$expression)';
	}

	/** Operand `index` of `row` as a C value of type `to`. */
	function operandAs(row:Int, index:Int, to:Int):String {
		var value = body.operand(row, index);
		if (nullValues[value] && types.isPointer(to))
			return "NULL";
		return convert(v(value), typeOf(value), to);
	}

	/** An assignment of `expression`, of type `from`, to `row`'s output, or the bare expression when the output is void. */
	function assign(row:Int, expression:String, from:Int):Void {
		var output = body.output(row);
		if (!output.exists() || types.isVoid(typeOf(output))) {
			line(expression + ";");
			return;
		}
		line('${v(output)} = ${types.isVoid(from) ? expression : convert(expression, from, typeOf(output))};');
	}

	function nullCheck(row:Int, receiver:IrValueId, ?field:String):Void {
		if (nonNull.has(row) || scalarLocals.get(receiver) != null)
			return;
		// The JIT names the field a failed check was for; a check before anything else reads "Null access".
		if (field != null)
			line('if( !${v(receiver)} ) hl_jit_null_field_access(hl_hash_utf8(${HlcModule.quote(field)}));');
		else
			line('if( !${v(receiver)} ) hl_null_access();');
	}

	function typeAddress(type:Int):String
		return '(&hlc_types[$type])';

	function globalAddress(global:Int):String
		return '(${types.cType(module.code.globals[global])}*)(hlc_globals + ${module.globalOffsets[global]})';

	function lowerRow(row:Int, traps:Map<Int, Bool>):Void {
		var opcode = body.opcode(row), output = body.output(row);
		switch opcode {
			case IrOpcode.Phi, IrOpcode.ConstVoid, IrOpcode.Catch:
			case IrOpcode.ConstInt:
				var value = body.aux(row);
				assign(row, value == -2147483648 ? "(-2147483647 - 1)" : Std.string(value), module.i32);
			case IrOpcode.ConstFloat:
				var bits = haxe.io.FPHelper.doubleToI64(body.float(row));
				assign(row, 'hlc_f64(0x${StringTools.hex(bits.high, 8)}u,0x${StringTools.hex(bits.low, 8)}u)',
					module.f64);
			case IrOpcode.PointerOffset:
				// `__hl_bytes_offset`, which `HlLower` folds into the access when it can.
				line('${v(output)} = (${types.cType(typeOf(output))})((char*)${v(body.operand(row, 0))} + ${v(body.operand(row, 1))});');
			case IrOpcode.MemoryLoad:
				var size = body.aux(row) >> 1,
					signed = body.aux(row) & 1 == 1,
					address = '(char*)${v(body.operand(row, 0))}';
				if (size == 1)
					line('${v(output)} = *(${signed ? "signed" : "unsigned"} char*)($address);');
				else if (size == 2)
					line('{ ${signed ? "short" : "unsigned short"} t; memcpy(&t,$address,2); ${v(output)} = t; }');
				else
					line('memcpy(&${v(output)},$address,sizeof(${v(output)}));');
			case IrOpcode.MemoryStore:
				var size = body.aux(row),
					address = '(char*)${v(body.operand(row, 0))}',
					value = v(body.operand(row, 1));
				if (size == 1)
					line('*(unsigned char*)($address) = (unsigned char)$value;');
				else if (size == 2)
					line('{ unsigned short t = (unsigned short)$value; memcpy($address,&t,2); }');
				else
					line('memcpy($address,&$value,sizeof($value));');
			case IrOpcode.ConstBool:
				assign(row, body.aux(row) == 1 ? "true" : "false", module.bool);
			case IrOpcode.ConstNull:
				if (isEnumTag(output))
					assign(row, "0", module.i32);
				else
					line('${v(output)} = NULL;');
			case IrOpcode.ConstString:
				var global = module.symbols.internStringConstant(body.string(row));
				assign(row, '*${globalAddress(global)}', module.code.globals[global]);
			case IrOpcode.TypeValue:
				assign(row, typeAddress(HlRemap.typeIndex(module.symbols, body.typeOperand(row))), module.typeRef);
			case IrOpcode.ToDyn:
				var value = body.operand(row, 0), from = typeOf(value);
				if (arrayRecast(row))
					return;
				if (isDynamic(from))
					line('${v(output)} = (vdynamic*)${v(value)};');
				else
					line('${v(output)} = hl_make_dyn(&${v(value)},${typeAddress(from)});');
			case IrOpcode.IntToFloat, IrOpcode.FloatToFloat, IrOpcode.IntToInt64, IrOpcode.FloatToInt, IrOpcode.Upcast:
				line('${v(output)} = (${types.cType(typeOf(output))})${v(body.operand(row, 0))};');
			case IrOpcode.SafeCast:
				lowerCast(row);
			case IrOpcode.GlobalGet:
				var global = module.symbols.requireGlobalIndex(body.symbol(row).name);
				assign(row, '*${globalAddress(global)}', module.code.globals[global]);
			case IrOpcode.GlobalSet:
				var global = module.symbols.requireGlobalIndex(body.symbol(row).name);
				line('*${globalAddress(global)} = ${operandAs(row, 0, module.code.globals[global])};');
			case IrOpcode.Add, IrOpcode.Sub, IrOpcode.Mul, IrOpcode.Div, IrOpcode.Mod, IrOpcode.BitAnd, IrOpcode.BitXor,
				IrOpcode.BitOr, IrOpcode.ShiftLeft, IrOpcode.ShiftRight, IrOpcode.UnsignedShiftRight:
				lowerArithmetic(row, opcode);
			case IrOpcode.Less, IrOpcode.LessEqual, IrOpcode.Equal:
				line('${v(output)} = ${comparison(row, opcode)};');
			case IrOpcode.Call:
				lowerCall(row);
			case IrOpcode.StaticClosure:
				var slot = module.requireSlot(body.symbol(row).name), id = temporaries++;
				line('static vclosure cl$id;');
				line('if( !cl$id.t ) { cl$id.fun = ${module.functionPointer(slot)}; cl$id.t = ${typeAddress(module.slotType(slot))}; }');
				assign(row, '&cl$id', module.dyn);
			case IrOpcode.InstanceClosure:
				var slot = module.requireSlot(body.symbol(row).name), receiver = body.operand(row, 0);
				nullCheck(row, receiver);
				assign(row,
					'hl_alloc_closure_ptr(${typeAddress(module.slotType(slot))},${module.functionPointer(slot)},(void*)${v(receiver)})',
					module.dyn);
			case IrOpcode.CallClosure:
				lowerClosureCall(row);
			case IrOpcode.ToVirtual:
				assign(row, 'hl_to_virtual(${typeAddress(typeOf(output))},(vdynamic*)${v(body.operand(row, 0))})',
					module.dyn);
			case IrOpcode.MethodCall:
				lowerMethodCall(row);
			case IrOpcode.ValueInit if (scalarLocals.get(output) != null):
				var local = scalarLocals.get(output);
				for (field in local.declarations) {
					var slot = local.fields.get(field.name);
					if (!types.isVoid(scalarLocalTypes[slot]))
						line('s$slot = ${types.isPointer(scalarLocalTypes[slot]) ? "NULL" : "0"};');
				}
			case IrOpcode.NewObject, IrOpcode.ValueInit:
				var type = typeOf(output);
				switch types.kind(type) {
					case Obj, Struct: assign(row, 'hl_alloc_obj(${typeAddress(type)})', module.dyn);
					case Virtual: assign(row, 'hl_alloc_virtual(${typeAddress(type)})', module.dyn);
					case DynObj: assign(row, 'hl_alloc_dynobj()', module.dyn);
					default: throw unsupported('allocation of ${types.typeName(type)}');
				}
			case IrOpcode.FieldGet if (scalarLocals.get(body.operand(row, 0)) != null):
				var slot = scalarLocals.get(body.operand(row, 0)).fields.get(body.symbol(row).name);
				assign(row, 's$slot', scalarLocalTypes[slot]);
			case IrOpcode.FieldSet if (scalarLocals.get(body.operand(row, 0)) != null):
				var slot = scalarLocals.get(body.operand(row, 0)).fields.get(body.symbol(row).name);
				line('s$slot = ${operandAs(row, 1, scalarLocalTypes[slot])};');
			case IrOpcode.FieldGet:
				var object = body.operand(row, 0), name = body.symbol(row).name;
				nullCheck(row, object, name);
				if (types.kind(typeOf(object)) == HlType.Virtual) {
					virtualFieldGet(row, object, name);
					return;
				}
				var field = fieldOf(object, name),
					place = '((${types.structName(objectType(object))}*)${v(object)})->f${field.index}';
				// An inline record is read as a pointer into its owner, as the JIT reads an HPACKED field.
				if (types.kind(field.type) == HlType.Packed)
					line('${v(body.output(row))} = (${types.cType(typeOf(body.output(row)))})&$place;');
				else {
					var storage = integerStorage(body.valueType(object), name, field.type);
					if (storage != null && (storage.size < 4 || types.kind(typeOf(body.output(row))) == HlType.I64))
						// As `HlLower.lowerFieldGet`: a narrow stored integer is widened by its signedness.
						line('${v(body.output(row))} = (${types.cType(typeOf(body.output(row)))})(${storageType(storage)})$place;');
					else
						assign(row, place, field.type);
				}
			case IrOpcode.FieldSet:
				var object = body.operand(row, 0), name = body.symbol(row).name;
				nullCheck(row, object, name);
				if (types.kind(typeOf(object)) == HlType.Virtual) {
					virtualFieldSet(row, object, name);
					return;
				}
				var field = fieldOf(object, name),
					slot = '((${types.structName(objectType(object))}*)${v(object)})->f${field.index}';
				if (types.kind(field.type) == HlType.Packed)
					line('hl_gc_copy_packed(&$slot,${v(body.operand(row, 1))},sizeof($slot),NULL);');
				else if (integerStorage(body.valueType(object), name, field.type) != null)
					line('$slot = (${types.cType(field.type)})${v(body.operand(row, 1))};');
				else
					store(slot, operandAs(row, 1, field.type), field.type);
			case IrOpcode.ArrayGet:
				var array = body.operand(row, 0), index = body.operand(row, 1);
				requireArray(array);
				nullCheck(row, array);
				line('hl_array_check(${v(array)},${v(index)});');
				assign(row, 'hl_aptr(${v(array)},${types.cType(typeOf(output))})[${v(index)}]', typeOf(output));
				if (rawArray(array))
					validatedAccesses.set('$array:$index', true);
			case IrOpcode.ArraySet:
				var array = body.operand(row, 0), index = body.operand(row, 1), value = body.operand(row, 2);
				requireArray(array);
				nullCheck(row, array);
				var key = '$array:$index';
				// `HlLower.lowerRawArrayWrite`: an Int or Float array write that an earlier access in the block validated is
				// not tested again, so `a[i] += f()` keeps Haxe's rule when `f` shrinks the array.
				if (!rawArray(array))
					line('hl_array_ensure(${v(array)},${v(index)});');
				else if (!validatedAccesses.exists(key)) {
					line('if( (unsigned)${v(index)} >= (unsigned)${v(array)}->size ) hl_array_ensure(${v(array)},${v(index)});');
					validatedAccesses.set(key, true);
				}
				store('hl_aptr(${v(array)},${types.cType(typeOf(value))})[${v(index)}]', v(value), typeOf(value));
			case IrOpcode.ArraySize:
				var array = body.operand(row, 0);
				requireArray(array);
				nullCheck(row, array);
				assign(row, '${v(array)}->size', module.i32);
			case IrOpcode.IteratorNew:
				var array = body.operand(row, 0);
				nullCheck(row, array);
				callSlot(row, module.requireSlot("__iterator_new"), ['(vdynamic*)${v(array)}'], [module.dyn]);
			case IrOpcode.IteratorHasNext:
				nullCheck(row, body.operand(row, 0));
				callSlot(row, module.requireSlot("__iterator_has_next"), [v(body.operand(row, 0))],
					[typeOf(body.operand(row, 0))]);
			case IrOpcode.IteratorNext:
				nullCheck(row, body.operand(row, 0));
				var next = compiler.hl.lower.HlLower.iteratorNextNative(body.valueType(output)),
					slot = module.requireSlot(next.name),
					call = callExpression(slot, [v(body.operand(row, 0))],
						[typeOf(body.operand(row, 0))]);
				if (types.kind(module.slotResult(slot)) == HlType.Dyn && !isDynamic(typeOf(output))) {
					var id = temporaries++;
					line('{ vdynamic *t$id = $call;');
					line('${v(output)} = ${dynamicCast('t$id', module.dyn, typeOf(output))}; }');
				} else
					assign(row, call, module.slotResult(slot));
			case IrOpcode.MakeEnum:
				lowerMakeEnum(row);
			case IrOpcode.EnumIndex:
				var value = body.operand(row, 0);
				nullCheck(row, value);
				if (isEnumTag(value))
					line('${v(output)} = ${v(value)} - 1;');
				else
					line('${v(output)} = ((venum*)${v(value)})->index;');
			case IrOpcode.EnumField:
				var value = body.operand(row, 0), constructor = body.auxInt(row, 0), field = body.auxInt(row, 1);
				nullCheck(row, value);
				assign(row,
					'*(${types.cType(typeOf(output))}*)((char*)${v(value)} + ${enumOffset(typeOf(value), constructor, field)})',
					typeOf(output));
			case IrOpcode.BeginTry:
				var catchBlock = body.auxInt(row, 0), handler = catchValue(catchBlock);
				if (body.auxInt(row, 2) == 1) {
					line('hl_trap(trap$catchBlock.trap,${v(handler)},b$catchBlock);');
					line('hl_cleanup_trap_enter(&trap$catchBlock);');
				} else
					line('hl_trap(trap$catchBlock,${v(handler)},b$catchBlock);');
			case IrOpcode.EndTry:
				var catchBlock = body.auxInt(row, 0);
				if (body.auxInt(row, 1) == 1) {
					line('hl_cleanup_trap_leave(&trap$catchBlock);');
					line('hl_endtrap(trap$catchBlock.trap);');
				} else
					line('hl_endtrap(trap$catchBlock);');
			default:
				throw unsupported('IR opcode ${(opcode : Int)}');
		}
	}

	/** The value a catch block's `Catch` row defines, which its trap stores the exception in. */
	function catchValue(blockId:Int):IrValueId {
		var block = body.blockIndex(blockId), row = body.firstRow(block);
		while (row >= 0) {
			switch body.opcode(row) {
				case IrOpcode.Catch:
					return body.output(row);
				case IrOpcode.Phi:
					throw unsupported('a phi in catch block $blockId');
				default:
			}
			row = body.nextRow(row);
		}
		throw new InternalError('Catch block $blockId of ${body.name} has no catch value');
	}

	/** A store into the heap: a pointer goes through the incremental collector's write barrier, as the JIT's stores do. */
	function store(slot:String, value:String, type:Int):Void
		if (types.isPointer(type))
			line('hl_gc_store_ref(&$slot,(void*)$value,NULL);');
		else
			line('$slot = $value;');

	/** The IR name of an object or interface value's type, which the symbol table's method slots are keyed by. */
	function irTypeName(value:IrValueId):String
		return switch body.valueType(value) {
			case Obj(name), Virtual(name): name;
			default: throw new InternalError('IR value ${(value : Int)} of ${body.name} is not an object');
		};

	/**
	 * Whether `value` is a payload-free enum in tag storage (`index + 1`, 0 for null). Decided by the IR type, as `HlLower`
	 * decides it: in a release build a tag nothing boxes has the plain I32 runtime type.
	 */
	function isEnumTag(value:IrValueId):Bool
		return switch body.valueType(value) {
			case EnumTag(_): true;
			default: false;
		};

	/**
	 * Whether ToDyn row `row` boxes an array only for the next row to cast it back to an array, as a coercion between array
	 * types does: as in `HlLower`, the cast takes the array itself and no box is made (HashLink arrays carry no element type).
	 */
	function arrayRecast(row:Int):Bool {
		var boxed = body.output(row), next = body.nextRow(row);
		return isArrayType(body.valueType(body.operand(row, 0))) && next >= 0 && body.opcode(next) == IrOpcode.SafeCast
			&& (body.operand(next, 0):Int) == (boxed:Int) && isArrayType(body.valueType(body.output(next)))
			&& uses[boxed] == 1;
	}

	static function isArrayType(type:IrType):Bool
		return switch type {
			case Array(_): true;
			default: false;
		};

	/** The native storage of an integer field (`HlLower.internNativeStorage` has one only for those), or null. */
	function integerStorage(type:IrType, name:String, fieldType:Int):Null<compiler.ir.Ir.IrScalarStorage>
		return switch types.kind(fieldType) {
			case Ui8, Ui16, I32, I64: module.fieldStorage(type, name);
			default: null;
		};

	/** The C integer type of a native storage width and signedness. */
	static function storageType(storage:compiler.ir.Ir.IrScalarStorage):String
		return switch storage.size {
			case 1: storage.signed ? "signed char" : "unsigned char";
			case 2: storage.signed ? "short" : "unsigned short";
			case 4: storage.signed ? "int" : "unsigned int";
			default: storage.signed ? "int64" : "uint64";
		};

	/** Whether `array` holds Int or Float elements in place, the arrays `HlLower` writes inline. */
	function rawArray(array:IrValueId):Bool
		return switch body.valueType(array) {
			case Array(I32), Array(F64): true;
			default: false;
		};

	function requireArray(array:IrValueId):Void
		if (types.kind(typeOf(array)) != HlType.Array)
			throw unsupported('array access on ${types.typeName(typeOf(array))}');

	function objectType(object:IrValueId):Int {
		var type = typeOf(object);
		if (!types.isObject(type))
			throw unsupported('field access on ${types.typeName(type)}');
		return type;
	}

	function fieldOf(object:IrValueId, name:String):HlcField {
		var type = objectType(object);
		for (field in types.fields(type))
			if (field.name == name)
				return field;
		throw new InternalError('Object ${types.typeName(type)} has no field $name in ${body.name}');
	}

	function enumOffset(type:Int, constructor:Int, field:Int):String
		return 'hlc_types[$type].tenum->constructs[$constructor].offsets[$field]';

	static function isDynamicKind(kind:HlType):Bool
		return switch kind {
			case Dyn, Fun, Obj, Array, Virtual, DynObj, Enum, Null: true;
			default: false;
		};

	function isDynamic(type:Int):Bool
		return isDynamicKind(types.kind(type));

	/** `HlLower`'s `SafeCast`, as the JIT does it: a checked cast through the runtime's `hl_dyn_cast*` (`emit_dyn_cast`). */
	function lowerCast(row:Int):Void {
		var value = body.operand(row, 0), output = body.output(row), previous = body.previousRow(row);
		if (previous >= 0 && body.opcode(previous) == IrOpcode.ToDyn && arrayRecast(previous)) {
			line('${v(output)} = (varray*)${v(body.operand(previous, 0))};');
			return;
		}
		line('${v(output)} = ${dynamicCast(v(value), typeOf(value), typeOf(output))};');
	}

	function dynamicCast(expression:String, from:Int, to:Int):String {
		var target = types.cType(to);
		// The runtime reads the value through a pointer: a named copy gives it one.
		var source = '(${types.cType(from)}[]){$expression}';
		return switch types.kind(to) {
			case F64: 'hl_dyn_castd($source,${typeAddress(from)})';
			case F32: 'hl_dyn_castf($source,${typeAddress(from)})';
			case I64, Guid: 'hl_dyn_casti64($source,${typeAddress(from)})';
			case I32, Ui8, Ui16, Bool,
				EnumTag: '($target)hl_dyn_casti($source,${typeAddress(from)},${typeAddress(to)})';
			default: '($target)hl_dyn_castp($source,${typeAddress(from)},${typeAddress(to)})';
		};
	}

	function lowerArithmetic(row:Int, opcode:IrOpcode):Void {
		var output = body.output(row),
			type = typeOf(output),
			left = v(body.operand(row, 0)),
			right = v(body.operand(row, 1)),
			kind = types.kind(type);
		var float = kind == HlType.F32 || kind == HlType.F64, wide = kind == HlType.I64, bits = wide ? 63 : 31;
		var expression = switch opcode {
			case IrOpcode.Add: '$left + $right';
			case IrOpcode.Sub: '$left - $right';
			case IrOpcode.Mul: '$left * $right';
			case IrOpcode.Div if (float): '$left / $right';
			// HashLink's integer division by 0 or -1 never traps (`hl2c`, the JIT's OSDiv).
			case IrOpcode.Div: '($right == 0 || $right == -1) ? $left * $right : $left / $right';
			case IrOpcode.Mod if (kind == HlType.F32): 'fmodf($left,$right)';
			case IrOpcode.Mod if (float): 'fmod($left,$right)';
			case IrOpcode.Mod: '($right == 0 || $right == -1) ? 0 : $left % $right';
			case IrOpcode.BitAnd: '$left & $right';
			case IrOpcode.BitXor: '$left ^ $right';
			case IrOpcode.BitOr: '$left | $right';
			case IrOpcode.ShiftLeft: '$left << ($right & $bits)';
			case IrOpcode.ShiftRight: '$left >> ($right & $bits)';
			default: '(${wide ? "int64" : "int"})((${wide ? "uint64" : "unsigned"})$left >> ($right & $bits))';
		};
		line('${v(output)} = $expression;');
	}

	/** A comparison as a C condition, with the semantics the JIT gives the same HashLink jump (`emit_jump_dyn`). */
	function comparison(row:Int, opcode:IrOpcode):String {
		var left = body.operand(row, 0), right = body.operand(row, 1);
		var operation = opcode == IrOpcode.Less ? "<" : opcode == IrOpcode.LessEqual ? "<=" : "==";
		var leftType = typeOf(left), rightType = typeOf(right), a = v(left), b = v(right);
		if (opcode == IrOpcode.Equal && (nullValues[left] || nullValues[right])
			&& !isEnumTag(nullValues[left] ? right : left))
			return nullValues[left] ? '(${v(right)} == NULL)' : '(${v(left)} == NULL)';
		var leftKind = types.kind(leftType), rightKind = types.kind(rightType);
		if (leftKind == HlType.Dyn || rightKind == HlType.Dyn || leftKind == HlType.Fun || rightKind == HlType.Fun)
			return '(hl_dyn_compare((vdynamic*)$a,(vdynamic*)$b) $operation 0)';
		switch leftKind {
			case Type:
				if (opcode != IrOpcode.Equal)
					throw unsupported("an ordering of types");
				return 'hl_same_type($a,$b)';
			case Null:
				if (opcode != IrOpcode.Equal)
					throw unsupported("an ordering of nullable values");
				var field = dynamicField(types.parameter(leftType));
				return '($a == $b || ($a && $b && $a->v.$field == $b->v.$field))';
			case Virtual if (rightKind == HlType.Obj):
				return '($a == (vvirtual*)$b || ($a && $a->value == (vdynamic*)$b))';
			case Virtual:
				return '($a == $b || ($a && $b && $a->value && $a->value == $b->value))';
			case Obj | Struct if (rightKind == HlType.Virtual):
				return '($b == (vvirtual*)$a || ($b && $b->value == (vdynamic*)$a))';
			case Obj | Struct:
				var compare = types.methodFunction(leftType, "__compare");
				if (compare >= 0 && module.isCompare(compare)) {
					var call =
						'${module.functionPointer(compare)}(${convert(a, leftType, module.slotArgument(compare, 0))},(vdynamic*)$b)';
					return opcode == IrOpcode.Equal
						? '((void*)$a == (void*)$b || ($a && $b && $call == 0))' : '($a && $b && $call $operation 0)';
				}
				return '((void*)$a $operation (void*)$b)';
			default:
				if (types.isPointer(leftType))
					return '((void*)$a $operation (void*)$b)';
				return '($a $operation $b)';
		}
	}

	/** The `vdynamic` value field a boxed value of type `type` is in (`hl2c`'s `dyn_value_field`). */
	function dynamicField(type:Int):String
		return switch types.kind(type) {
			case Ui8: "ui8";
			case Ui16: "ui16";
			case I32, EnumTag: "i";
			case I64, Guid: "i64";
			case F32: "f";
			case F64: "d";
			case Bool: "b";
			default: "ptr";
		};

	/** A call of slot `slot`: a direct C call, or through the slot table for a native the loader resolved. */
	function callExpression(slot:Int, arguments:Array<String>, argumentTypes:Array<Int>):String {
		var parameters = module.slotArguments(slot);
		if (parameters.length != arguments.length)
			throw new InternalError('Call of ${module.slotName(slot)} with ${arguments.length} arguments for ${parameters.length} in ${body.name}');
		var converted = [for (index in 0...arguments.length) convert(arguments[index], argumentTypes[index],
			parameters[index])];
		return '${module.functionPointer(slot)}(${converted.join(",")})';
	}

	function callSlot(row:Int, slot:Int, arguments:Array<String>, argumentTypes:Array<Int>):Void
		assign(row, callExpression(slot, arguments, argumentTypes), module.slotResult(slot));

	function operandsFrom(row:Int, from:Int):Array<IrValueId>
		return [for (index in from...body.operandCount(row)) body.operand(row, index)];

	function lowerCall(row:Int):Void {
		var name = body.symbol(row).name, output = body.output(row);
		switch name {
			case compiler.ir.IrReceiverCheck.NAME:
				nullCheck(row, body.operand(row, 0));
				return;
			case compiler.ir.IrReferenceIdentity.NAME:
				line('${v(output)} = (void*)${v(body.operand(row, 0))} == (void*)${v(body.operand(row, 1))};');
				return;
			case compiler.ir.IrExactTypeFacts.TEST:
				var object = v(body.operand(row, 0));
				line('${v(output)} = ($object ? ((vdynamic*)$object)->t : &hlt_void) == ${v(body.operand(row, 1))};');
				return;
			case compiler.ir.IrScalarWordBits.PACK, compiler.ir.IrScalarWordBits.UNPACK,
				compiler.ir.IrValueLaneReference.PACK,
				compiler.ir.IrValueLaneReference.UNPACK:
				line('${v(output)} = (${types.cType(typeOf(output))})${v(body.operand(row, 0))};');
				return;
			case compiler.ir.IrHlScalarRef.ADDRESS:
				line('${v(output)} = (${types.cType(typeOf(output))})&${v(body.operand(row, 0))};');
				return;
			case compiler.ir.IrHlScalarRef.LOAD:
				assign(row, '*${v(body.operand(row, 0))}', types.parameter(typeOf(body.operand(row, 0))));
				return;
			case compiler.ir.IrHlScalarRef.STORE:
				var reference = body.operand(row, 0), element = types.parameter(typeOf(reference));
				store('*${v(reference)}', operandAs(row, 1, element), element);
				return;
			default:
		}
		var slot = module.requireSlot(name), arguments = operandsFrom(row, 0);
		callSlot(row, slot, [for (value in arguments) nullValues[value] ? "NULL" : v(value)],
			[for (value in arguments) typeOf(value)]);
	}

	function lowerClosureCall(row:Int):Void {
		var closure = body.operand(row, 0), arguments = operandsFrom(row, 1), output = body.output(row);
		line('if( !${v(closure)} ) hl_null_access();');
		if (types.kind(typeOf(closure)) == HlType.Dyn) {
			var slot = module.requireSlot("__reflect_is_function");
			var error = module.symbols.internStringConstant("Cannot call a non-function value");
			line('if( !${callExpression(slot, [v(closure)], [typeOf(closure)])} ) hl_throw((vdynamic*)*${globalAddress(error)});');
			var id = temporaries++;
			line('{ vdynamic *args$id[] = {${[for (value in arguments) '(vdynamic*)${v(value)}'].concat(["NULL"]).join(",")}};');
			var call = 'hl_dyn_call((vclosure*)${v(closure)},args$id,${arguments.length})';
			if (!output.exists() || types.isVoid(typeOf(output)))
				line('$call; }');
			else if (isDynamic(typeOf(output)))
				line('${v(output)} = (${types.cType(typeOf(output))})$call; }');
			else
				line('vdynamic *r$id = $call; ${v(output)} = ${dynamicCast('r$id', module.dyn, typeOf(output))}; }');
			return;
		}
		var signature = types.signature(typeOf(closure)), result = types.cType(signature.result);
		var parameters = [for (type in signature.arguments) types.cType(type)];
		var values = [for (index in 0...arguments.length) convert(v(arguments[index]), typeOf(arguments[index]),
			signature.arguments[index])];
		var c = v(closure);
		var bound =
			'(($result (*)(${["void*"].concat(parameters).join(",")}))$c->fun)(${['$c->value'].concat(values).join(",")})';
		var plain =
			'(($result (*)(${parameters.length == 0 ? "void" : parameters.join(",")}))$c->fun)(${values.join(",")})';
		if (types.isVoid(signature.result))
			line('if( $c->hasValue ) $bound; else $plain;');
		else
			assign(row, '($c->hasValue ? $bound : $plain)', signature.result);
	}

	function lowerMethodCall(row:Int):Void {
		var object = body.operand(row, 0),
			name = body.symbol(row).name,
			arguments = operandsFrom(row, 0),
			type = typeOf(object);
		nullCheck(row, object);
		var direct = module.valueMethod(body.valueType(object), name);
		if (direct != null) {
			var slot = module.requireSlot(direct);
			callSlot(row, slot, [for (value in arguments) v(value)], [for (value in arguments) typeOf(value)]);
			return;
		}
		switch types.kind(type) {
			case Obj:
				var slot = module.symbols.requireObjectMethodIndex(irTypeName(object), name),
					function_ = module.prototypeFunction(type, slot);
				var parameters = module.slotArguments(function_), result = module.slotResult(function_);
				var values = [for (index in 0...arguments.length) convert(v(arguments[index]), typeOf(arguments[index]),
					parameters[index])];
				var pointer =
					'((${types.cType(result)} (*)(${[for (p in parameters) types.cType(p)].join(",")}))${v(object)}->t->vobj_proto[$slot])';
				assign(row, '$pointer(${values.join(",")})', result);
			case Virtual:
				var slot = module.symbols.requireInterfaceMethodIndex(irTypeName(object), name),
					field = types.virtualField(type, slot),
					signature = types.signature(field.type),
					o = v(object);
				var parameters = [for (argument in signature.arguments) types.cType(argument)];
				var values = [
					for (index in 1...arguments.length)
						convert(v(arguments[index]), typeOf(arguments[index]), signature.arguments[index - 1])
				];
				var method =
					'((${types.cType(signature.result)} (*)(${["vdynamic*"].concat(parameters).join(",")}))hl_vfields($o)[$slot])';
				var direct = '$method(${['$o->value'].concat(values).join(",")})';
				var output = body.output(row),
					id = temporaries++,
					hasResult = output.exists() && !types.isVoid(signature.result);
				// As the JIT: the method the virtual has bound, or a dynamic call by name on the object behind it.
				line('if( hl_vfields($o)[$slot] ) ${hasResult ? v(output) + " = " + convert(direct, signature.result, typeOf(output)) : direct}; else {');
				line('\tstatic int h$id; if( !h$id ) h$id = hl_hash_utf8(${HlcModule.quote(field.name)});');
				var boxed = [
					for (index in 0...values.length)
						types.isPointer(signature.arguments[index])
						? '(void*)${values[index]}' : '(void*)&(${parameters[index]}){${values[index]}}'
				];
				line('\tvoid *args$id[] = {${boxed.concat(["NULL"]).join(",")}};');
				if (!hasResult)
					line('\thl_dyn_call_obj($o->value,${typeAddress(field.type)},h$id,args$id,NULL);');
				else if (types.isPointer(signature.result))
					line('\t${v(output)} = (${types.cType(typeOf(output))})hl_dyn_call_obj($o->value,${typeAddress(field.type)},h$id,args$id,NULL);');
				else {
					line('\tvdynamic r$id; hl_dyn_call_obj($o->value,${typeAddress(field.type)},h$id,args$id,&r$id);');
					line('\t${v(output)} = (${types.cType(typeOf(output))})r$id.v.${dynamicField(signature.result)};');
				}
				line("}");
			default:
				throw unsupported('a method call on ${types.typeName(type)}');
		}
	}

	/** A field of a virtual: through its field table, or by name on the object behind it (the JIT's `OField` on an HVIRTUAL). */
	function virtualFieldGet(row:Int, object:IrValueId, name:String):Void {
		var type = typeOf(object),
			slot = virtualSlot(type, name),
			field = types.virtualField(type, slot),
			o = v(object),
			output = body.output(row),
			id = temporaries++,
			cType = types.cType(field.type);
		line('if( hl_vfields($o)[$slot] ) ${v(output)} = ${convert('*($cType*)hl_vfields($o)[$slot]', field.type, typeOf(output))}; else {');
		line('\tstatic int h$id; if( !h$id ) h$id = hl_hash_utf8(${HlcModule.quote(name)});');
		line('\t${v(output)} = ${convert(dynamicGet('$o->value', 'h$id', field.type), field.type, typeOf(output))};');
		line("}");
	}

	function virtualFieldSet(row:Int, object:IrValueId, name:String):Void {
		var type = typeOf(object),
			slot = virtualSlot(type, name),
			field = types.virtualField(type, slot),
			o = v(object),
			value = operandAs(row, 1, field.type),
			id = temporaries++,
			cType = types.cType(field.type);
		line('if( hl_vfields($o)[$slot] ) {');
		store('*($cType*)hl_vfields($o)[$slot]', value, field.type);
		line('} else {');
		line('\tstatic int h$id; if( !h$id ) h$id = hl_hash_utf8(${HlcModule.quote(name)});');
		line('\t${dynamicSet('$o->value', 'h$id', field.type, value)};');
		line("}");
	}

	function virtualSlot(type:Int, name:String):Int {
		var slot = types.virtualSlot(type, name);
		if (slot < 0)
			throw new InternalError('Virtual ${types.typeName(type)} has no field $name in ${body.name}');
		return slot;
	}

	/** `hl_dyn_get*` for a value of type `type` (the JIT's `get_dynget`). */
	function dynamicGet(object:String, hash:String, type:Int):String
		return switch types.kind(type) {
			case F32: 'hl_dyn_getf((vdynamic*)$object,$hash)';
			case F64: 'hl_dyn_getd((vdynamic*)$object,$hash)';
			case I64, Guid: 'hl_dyn_geti64((vdynamic*)$object,$hash)';
			case I32, Ui8, Ui16, Bool,
				EnumTag: '(${types.cType(type)})hl_dyn_geti((vdynamic*)$object,$hash,${typeAddress(type)})';
			default: '(${types.cType(type)})hl_dyn_getp((vdynamic*)$object,$hash,${typeAddress(type)})';
		};

	function dynamicSet(object:String, hash:String, type:Int, value:String):String
		return switch types.kind(type) {
			case F32: 'hl_dyn_setf((vdynamic*)$object,$hash,$value)';
			case F64: 'hl_dyn_setd((vdynamic*)$object,$hash,$value)';
			case I64, Guid: 'hl_dyn_seti64((vdynamic*)$object,$hash,$value)';
			case I32, Ui8, Ui16, Bool, EnumTag: 'hl_dyn_seti((vdynamic*)$object,$hash,${typeAddress(type)},$value)';
			default: 'hl_dyn_setp((vdynamic*)$object,$hash,${typeAddress(type)},(void*)$value)';
		};

	function lowerMakeEnum(row:Int):Void {
		var output = body.output(row), type = typeOf(output), constructor = body.auxInt(row, 1);
		if (isEnumTag(output)) {
			line('${v(output)} = ${constructor + 1};');
			return;
		}
		var arguments = operandsFrom(row, 0);
		if (arguments.length == 0) {
			// As `HlLower.lowerEnumConstant`: a constructor without fields is made once and kept in a global.
			var global = module.symbols.internEnumConstant(body.symbol(row).name, constructor);
			line('${v(output)} = (venum*)*${globalAddress(global)};');
			line('if( !${v(output)} ) { ${v(output)} = hl_alloc_enum(${typeAddress(type)},$constructor); *${globalAddress(global)} = (${types.cType(module.code.globals[global])})${v(output)}; }');
			return;
		}
		line('${v(output)} = hl_alloc_enum(${typeAddress(type)},$constructor);');
		for (index in 0...arguments.length) {
			var value = arguments[index];
			line('*(${types.cType(typeOf(value))}*)((char*)${v(output)} + ${enumOffset(type, constructor, index)}) = ${nullValues[value] ? "NULL" : v(value)};');
		}
	}

	function lowerTerminator(block:Int, row:Int):Void {
		var id = body.blockId(block);
		switch body.opcode(row) {
			case IrOpcode.Unreachable:
				line('${module.functionPointer(module.requireSlot("__unreachable"))}();');
				line("HL_UNREACHABLE;");
			case IrOpcode.Return:
				var value = body.operand(row, 0);
				if (types.isVoid(typeOf(value)))
					line("return;");
				else
					line('return ${operandAs(row, 0, functionResult)};');
			case IrOpcode.Throw:
				line('hl_throw((vdynamic*)${v(body.operand(row, 0))});');
			case IrOpcode.Rethrow:
				line('hl_rethrow((vdynamic*)${v(body.operand(row, 0))});');
			case IrOpcode.Jump:
				line(edge(id, body.aux(row)) + 'goto b${body.aux(row)};');
			case IrOpcode.Branch:
				var yes = body.auxInt(row, 0), no = body.auxInt(row, 1);
				line('if( ${v(body.operand(row, 0))} ) { ${edge(id, yes)}goto b$yes; } else { ${edge(id, no)}goto b$no; }');
			case IrOpcode.Switch:
				var count = body.successorCount(row);
				line('switch( ${v(body.operand(row, 0))} ) {');
				for (index in 0...count - 1) {
					var target = body.successor(row, index);
					line('case $index: ${edge(id, target)}goto b$target;');
				}
				var otherwise = body.successor(row, count - 1);
				line('default: ${edge(id, otherwise)}goto b$otherwise;');
				line("}");
			default:
				throw new InternalError('IR body row $row of ${body.name} is not a terminator');
		}
	}

	/** The phi assignments on the edge from block `from` to block `to`, as one parallel copy. */
	function edge(from:Int, to:Int):String {
		var block = body.blockIndex(to),
			row = body.firstRow(block),
			targets:Array<String> = [],
			values:Array<String> = [],
			cTypes:Array<String> = [];
		while (row >= 0 && body.opcode(row) == IrOpcode.Phi) {
			var output = body.output(row);
			if (!types.isVoid(typeOf(output)))
				for (index in 0...body.operandCount(row))
					if (body.auxInt(row, index) == from) {
						var value = body.operand(row, index);
						if ((value:Int) != (output:Int)) {
							targets.push(v(output));
							values.push(nullValues[value]
								&& types.isPointer(typeOf(output)) ? "NULL" : convert(v(value),
								typeOf(value), typeOf(output)));
							cTypes.push(types.cType(typeOf(output)));
						}
						break;
					}
			row = body.nextRow(row);
		}
		if (targets.length == 0)
			return "";
		if (targets.length == 1)
			return '${targets[0]} = ${values[0]}; ';
		var buffer = new StringBuf();
		for (index in 0...targets.length)
			buffer.add('${cTypes[index]} p$index = ${values[index]}; ');
		for (index in 0...targets.length)
			buffer.add('${targets[index]} = p$index; ');
		return '{ ${buffer.toString()}} ';
	}
}
