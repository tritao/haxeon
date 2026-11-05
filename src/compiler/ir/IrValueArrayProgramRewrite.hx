package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.SourceProvenance.Located;

/** Assemble the per-shape lowering after mutable places have been marked by the frontend. */
class IrValueArrayProgramRewrite {
	/** Discover every concrete struct array in the assembled program before generating any helpers. */
	public static function rewriteAll(program:IrProgram, pointerBits:Int, target:IrValueLaneTarget):Void {
		var values:Map<String, Bool> = [for (object in program.objects) if (object.isValue) object.name => true],
			elements:Map<String, IrType> = [];
		function visit(type:IrType):Void switch type {
			case Array(element):
				switch element {
					case Obj(name) | Nullable(Obj(name)) if (values.exists(name)):
						elements.set(haxe.crypto.Base64.encode(compiler.ir.codec.IrTypeCodec.encode(element)), element);
					default:
				}
				visit(element);
			case Nullable(element), Iterator(element): visit(element);
			case Function(arguments, result): for (argument in arguments) visit(argument); visit(result);
			default:
		}
		for (object in program.objects) for (field in object.fields) visit(field.type);
		for (item in program.enums) for (constructor in item.cases) for (argument in constructor.params) visit(argument);
		for (item in program.interfaces) for (method in item.methods) { for (argument in method.arguments) visit(argument); visit(method.result); }
		for (field in program.staticFields) visit(field.type);
		for (native in program.natives) { for (argument in native.arguments) visit(argument); visit(native.result); }
		for (fn in program.functions) {
			for (argument in fn.arguments) visit(argument.type);
			visit(fn.result);
			for (block in fn.blocks) for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null) visit(output.type);
				for (input in IrOperands.inputs(located.value)) visit(input.type);
				switch located.value { case TypeValue(_, type): visit(type); default: }
			}
		}
		var keys = [for (key in elements.keys()) key]; keys.sort(Reflect.compare);
		for (key in keys) rewrite(program, elements.get(key), pointerBits, target);
		IrVerifier.verifyValueArraysLowered(program);
	}

	public static function rewrite(program:IrProgram, element:IrType, pointerBits:Int, target:IrValueLaneTarget):Void {
		var declarations:Map<String, IrObject> = [for (object in program.objects) object.name => object],
			objects = IrObjectTable.of(declarations), factory = new IrValueArrayFactory(objects, element, pointerBits, target),
			elements = new IrValueArrayElements(element, factory.helpers, factory.bridge),
			methods = new IrValueArrayPlaceMethods(objects, element, factory.helpers),
			originals:Map<String, IrFunction> = [for (fn in program.functions) fn.name => fn], rewritten:Array<IrFunction> = [];
		var optional:Null<IrValueArrayOptionalComponents> = switch element {
			case Nullable(Obj(name)) if (declarations.exists(IrOptionalScalarFlow.wrapperName(name))):
				new IrValueArrayOptionalComponents(objects, element, factory.helpers);
			default: null;
		};
		for (fn in program.functions) {
			var ranged = IrValueArrayRangeRewrite.rewrite(fn, element, factory), roots = IrValueArrayPlaceRewrite.roots(ranged, element),
				current = roots.keys().hasNext() ? IrValueArrayPlaceRewrite.rewrite(ranged, element, objects, factory.helpers, methods, roots) : ranged;
			if (optional != null) current = IrValueArrayOptionalRewrite.rewrite(current, element, optional);
			current = IrValueArrayElementRewrite.rewrite(current, element, elements);
			current = rewriteDynamicViews(current);
			current = rewriteAllocations(current, element, factory.allocateName());
			rewritten.push(rewriteCasts(current, element, factory.retypeName()));
		}
		var generatedMethods = methods.generate(originals), generatedFactories = factory.functions(), generatedElements = elements.functions(),
			generatedOptional = optional == null ? [] : optional.functions(),
			generatedSlots = factory.helpers.functions();
		program.functions = rewritten.concat(generatedMethods).concat(generatedFactories).concat(generatedElements).concat(generatedOptional).concat(generatedSlots);
		var nullableScalars = false;
		for (slot in factory.layout.lanes.slots) if (slot.nullablePayload) nullableScalars = true;
		IrValueArrayScalarLowering.rewrite(program, element, target != HashLink || nullableScalars);
		var nativeNames:Map<String, Bool> = [for (native in program.natives) native.name => true];
		for (native in factory.natives().concat(factory.helpers.natives()).concat(elements.natives())) if (!nativeNames.exists(native.name)) {
			nativeNames.set(native.name, true); program.natives.push(native);
		}
		// Dynamic views can be introduced after initial assembly; their Wasm dispatch also needs all concrete storage operations.
		IrProgramAssembler.ensureArrayRuntime(program, false, false, false);
		for (native in program.natives) nativeNames.set(native.name, true);
		var dynamicNatives:Array<IrNative> = [
			{name:"__array_get_any", library:"haxeon_runtime", symbol:"__array_get_any", arguments:[Array(Dyn),I32], result:Dyn},
			{name:"__array_set_any", library:"haxeon_runtime", symbol:"__array_set_any", arguments:[Array(Dyn),I32,Dyn], result:Void},
			{name:"__array_push_any", library:"haxeon_runtime", symbol:"__array_push_any", arguments:[Array(Dyn),Dyn], result:I32},
			{name:"__array_unshift_any", library:"haxeon_runtime", symbol:"__array_unshift_any", arguments:[Array(Dyn),Dyn], result:I32},
			{name:"__array_insert_any", library:"haxeon_runtime", symbol:"__array_insert_any", arguments:[Array(Dyn),I32,Dyn], result:Void},
			{name:"__array_reverse_any", library:"haxeon_runtime", symbol:"__array_reverse_any", arguments:[Array(Dyn)], result:Void},
			{name:"__array_resize_any", library:"haxeon_runtime", symbol:"__array_resize_any", arguments:[Array(Dyn),I32], result:Void},
			{name:"__array_copy_any", library:"haxeon_runtime", symbol:"__array_copy_any", arguments:[Array(Dyn)], result:Array(Dyn)},
			{name:"__array_slice_any", library:"haxeon_runtime", symbol:"__array_slice_any", arguments:[Array(Dyn),I32,I32], result:Array(Dyn)},
			{name:"__array_splice_any", library:"haxeon_runtime", symbol:"__array_splice_any", arguments:[Array(Dyn),I32,I32], result:Array(Dyn)},
			{name:"__array_concat_any", library:"haxeon_runtime", symbol:"__array_concat_any", arguments:[Array(Dyn),Array(Dyn)], result:Array(Dyn)},
			{name:"__array_pop_any", library:"haxeon_runtime", symbol:"__array_pop_any", arguments:[Array(Dyn)], result:Dyn},
			{name:"__array_shift_any", library:"haxeon_runtime", symbol:"__array_shift_any", arguments:[Array(Dyn)], result:Dyn},
			{name:"__array_remove_at_any", library:"haxeon_runtime", symbol:"__array_remove_at_any", arguments:[Array(Dyn),I32], result:Void}
		];
		for (native in dynamicNatives) if (!nativeNames.exists(native.name)) { nativeNames.set(native.name, true); program.natives.push(native); }
	}

	/** A checked concrete view must install the lane representation on the shared dynamic header. */
	static function rewriteCasts(fn:IrFunction, element:IrType, retype:String):IrFunction {
		var next = 0, changed = false, blocks:Array<IrBlock> = [];
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id >= next) next = output.id + 1;
			for (input in IrOperands.inputs(located.value)) if (input.id >= next) next = input.id + 1;
		}
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) switch located.value {
				case SafeCast(out, input) if (Type.enumEq(out.type, Array(element)) && (switch (input.type) { case Dyn: true; default: false; })):
					var dynamicView = new IrValue(next++, "$value-array-dynamic-view", Array(Dyn));
					target.instructions.push(new Located(SafeCast(dynamicView, input), located.provenance));
					target.instructions.push(new Located(Call(out, retype, [dynamicView]), located.provenance));
					changed = true;
				default: target.instructions.push(located);
			}
			target.terminator = block.terminator; blocks.push(target);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	/** Dynamic views must dispatch by their runtime storage even when the frontend omitted native checks. */
	static function rewriteDynamicViews(fn:IrFunction):IrFunction {
		var next = 0, changed = false, blocks:Array<IrBlock> = [];
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id >= next) next = output.id + 1;
			for (input in IrOperands.inputs(located.value)) if (input.id >= next) next = input.id + 1;
		}
		for (block in fn.blocks) {
			var target = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = switch located.value {
					case ArrayGet(out, array, index) if (Type.enumEq(array.type, Array(Dyn)) && (switch (out.type) { case Dyn: true; default: false; })):
						changed = true; Call(out, "__array_get_any", [array, index]);
					case ArraySet(array, index, value) if (Type.enumEq(array.type, Array(Dyn)) && (switch (value.type) { case Dyn: true; default: false; })):
						changed = true; Call(new IrValue(next++, "$dynamic-array-write", Void), "__array_set_any", [array, index, value]);
					case Call(out, name, args) if ((name == "__array_push_ref" || name == "__array_unshift_ref" || name == "__array_insert_ref"
							|| name == "__array_reverse_ref" || name == "__array_resize_ref" || name == "__array_copy_ref"
							|| name == "__array_slice_ref" || name == "__array_splice_ref" || name == "__array_concat_ref"
							|| name == "__array_pop_ref" || name == "__array_shift_ref" || name == "__array_index_of_ref" || name == "__array_remove_ref")
							&& args.length > 0 && Type.enumEq(args[0].type, Array(Dyn))):
						changed = true; Call(out, name.substr(0, name.length - 3) + "any", args);
					default: located.value;
				};
				target.instructions.push(new Located(instruction, located.provenance));
			}
			target.terminator = block.terminator; blocks.push(target);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	static function rewriteAllocations(fn:IrFunction, element:IrType, allocator:String):IrFunction {
		var arrayType:IrType = Array(element), changed = false, blocks:Array<IrBlock> = [],
			typeValues:Map<Int, IrType> = [], uses:Map<Int, Int> = [];
		function use(value:IrValue):Void uses.set(value.id, (uses.exists(value.id) ? uses.get(value.id) : 0) + 1);
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value)) use(input);
				switch located.value {
					case TypeValue(out, type): typeValues.set(out.id, type);
					case Phi(_, inputs): for (input in inputs) use(input.value);
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): use(value);
				default:
			}
		}
		for (block in fn.blocks) {
			var target = new IrBlock(block.id), position = 0;
			while (position < block.instructions.length) {
				var located = block.instructions[position];
				var instruction = located.value;
				switch instruction {
					case Call(out, "__array_alloc_ref", arguments) if (Type.enumEq(out.type, arrayType)):
						if (arguments.length != 1) throw "Invalid array allocation";
						instruction = Call(out, allocator, arguments); changed = true;
					case Call(raw, "__array_alloc_typed_ref", arguments) if (arguments.length == 2 && position + 2 < block.instructions.length):
						var conversion = block.instructions[position + 1].value, castInstruction = block.instructions[position + 2].value;
						switch [conversion, castInstruction] {
							case [ToDyn(boxed, source), SafeCast(out, input)]
									if (source.id == raw.id && input.id == boxed.id && Type.enumEq(out.type, arrayType)):
								if (uses.get(raw.id) != 1 || uses.get(boxed.id) != 1 || !typeValues.exists(arguments[1].id)
										|| !Type.enumEq(typeValues.get(arguments[1].id), element))
									throw "Typed array allocation escapes or has an incompatible element type";
								instruction = Call(out, allocator, [arguments[0]]); position += 2; changed = true;
							default:
						}
					default:
				}
				target.instructions.push(new Located(instruction, located.provenance));
				position++;
			}
			target.terminator = block.terminator; blocks.push(target);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}
}
