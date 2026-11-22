package compiler.backend.c;

import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.HlWriter;

/**
 * `image.c` of a C build (docs/design/AOT_BACKEND.md): the module image the runtime builds its types, globals, natives and
 * constants from, the slot table, the generated functions by C name, the call trampolines, the tables the entry point fills
 * the files' pointers from, and the layouts the runtime checks. It is written last, from the tables of `module` once every
 * function is written, and is the one file that depends on table positions.
 */
class HlcImage {
	final module:HlcModule;
	final code:HlCode;
	final types:HlcTypes;

	public function new(module:HlcModule) {
		this.module = module;
		code = module.code;
		types = module.types;
	}

	/** The C calling shape of a value of type `type`, one letter of a trampoline's key; `hlc_main.c` spells it the same. */
	function shapeCode(type:Int):String
		return switch types.kind(type) {
			case Void: "v";
			case Bool: "b";
			case Ui8: "c";
			case Ui16: "s";
			case I32, EnumTag: "i";
			case I64, Guid: "l";
			case F32: "f";
			case F64: "d";
			default: "p";
		};

	static function shapeType(code:String):String
		return switch code {
			case "v": "void";
			case "b": "bool";
			case "c": "unsigned char";
			case "s": "unsigned short";
			case "i": "int";
			case "l": "int64";
			case "f": "float";
			case "d": "double";
			default: "void*";
		};

	/**
	 * The trampolines the runtime calls compiled functions through, and wraps closures in, which the JIT would make
	 * (`hl_setup.static_call`, `get_wrapper`): one pair per C calling shape of the program's function types, and of each with
	 * its first argument bound, keyed by the result's shape and the arguments' (`hlc_signatures`, in key order).
	 */
	function trampolines(buffer:StringBuf):Void {
		var keys:Map<String, Bool> = [];
		for (index in 0...code.types.length)
			switch types.kind(index) {
				case Fun, Method:
					var signature = types.signature(index),
						shapes = [for (argument in signature.arguments) shapeCode(argument)];
					keys.set(shapeCode(signature.result) + shapes.join(""), true);
					if (shapes.length > 0)
						keys.set(shapeCode(signature.result) + shapes.slice(1).join(""), true);
				default:
			}
		var sorted = [for (key in keys.keys()) key];
		sorted.sort(Reflect.compare);
		for (key in sorted) {
			var result = key.charAt(0), arguments = [for (index in 1...key.length) key.charAt(index)];
			var parameters = [for (argument in arguments) shapeType(argument)];
			var values = [
				for (index in 0...arguments.length)
					arguments[index] == "p" ? 'a[$index]' : arguments[index] == "b" || arguments[index] == "c"
					|| arguments[index] == "s"
					? '(${shapeType(arguments[index])})*(int*)a[$index]' : '*(${shapeType(arguments[index])}*)a[$index]'
			];
			var call =
				'((${shapeType(result)} (*)(${parameters.length == 0 ? "void" : parameters.join(",")}))f)(${values.join(",")})';
			buffer.add('static void *hlc_call_$key( void *f, void **a, vdynamic *out ) {\n\t');
			buffer.add(switch result {
				case "v": '$call;\n\treturn NULL;\n';
				case "b", "c", "s", "i": 'out->v.i = (int)$call;\n\treturn &out->v.i;\n';
				case "l": 'out->v.i64 = $call;\n\treturn &out->v.i64;\n';
				case "f": 'out->v.f = $call;\n\treturn &out->v.f;\n';
				case "d": 'out->v.d = $call;\n\treturn &out->v.d;\n';
				default: 'return $call;\n';
			});
			buffer.add("}\n");
			var declared = ["void *w"].concat([for (index in 0...arguments.length) '${parameters[index]} p$index']);
			var packed = [for (index in 0...arguments.length) arguments[index] == "p" ? 'p$index' : '&p$index'];
			buffer.add('static ${shapeType(result)} hlc_wrap_$key( ${declared.join(", ")} ) {\n');
			buffer.add('\tvoid *args[] = {${packed.concat(["NULL"]).join(",")}};\n\tvdynamic ret;\n');
			buffer.add(switch result {
				case "v": '\thl_wrapper_call(w,args,&ret);\n';
				case "b", "c", "s", "i": '\thl_wrapper_call(w,args,&ret);\n\treturn (${shapeType(result)})ret.v.i;\n';
				case "l": '\thl_wrapper_call(w,args,&ret);\n\treturn ret.v.i64;\n';
				case "f": '\thl_wrapper_call(w,args,&ret);\n\treturn ret.v.f;\n';
				case "d": '\thl_wrapper_call(w,args,&ret);\n\treturn ret.v.d;\n';
				default: '\treturn hl_wrapper_call(w,args,&ret);\n';
			});
			buffer.add("}\n");
		}
		buffer.add("const hlc_signature hlc_signatures[] = {\n");
		for (key in sorted)
			buffer.add('\t{"$key",hlc_call_$key,(void*)hlc_wrap_$key},\n');
		buffer.add('\t{NULL,NULL,NULL}};\nconst int hlc_signature_count = ${sorted.length};\n\n');
	}

	/**
	 * The definitions of the pointers `names` gives for `indices` of a table, and the table the entry point fills them from:
	 * `hlc_KIND_refs` (each pointer's address) and `hlc_KIND_ref_indices`, in index order.
	 */
	function references(buffer:StringBuf, type:String, kind:String, indices:Array<Int>, names:Int->String):Void {
		indices.sort((a, b) -> a - b);
		for (index in indices)
			buffer.add('$type *${names(index)};\n');
		buffer.add('const int hlc_${kind}_ref_count = ${indices.length};\n');
		buffer.add('$type **const hlc_${kind}_refs[] = {');
		for (index in indices)
			buffer.add('&${names(index)},');
		buffer.add('NULL};\nconst int hlc_${kind}_ref_indices[] = {${indices.concat([-1]).join(",")}};\n\n');
	}

	/**
	 * The module image: this module with every function body a stub, which the runtime decodes into its types, globals,
	 * natives and constants (`hl_code_read`, `hl_module_init`) before the slots are pointed at the C functions; the slot table;
	 * and the layouts the C code assumes, which the runtime checks against its own before running anything.
	 */
	public function write():String {
		var stubbed = new HlCode();
		stubbed.ints = code.ints;
		stubbed.floats = code.floats;
		stubbed.strings = code.strings;
		stubbed.types = code.types;
		stubbed.globals = code.globals;
		stubbed.natives = code.natives;
		stubbed.constants = code.constants;
		stubbed.entryPoint = code.entryPoint;
		// The functions' names, which stack traces show as the JIT's do.
		stubbed.debugSections =
			[for (section in code.debugSections) if (section.kind == HlWriter.FUNCTION_IDENTITIES) section];
		stubbed.functions = [for (fn in code.functions) {
			var signature = types.signature(fn.type);
			new HlFunction(fn.type, fn.functionIndex, signature.arguments.concat([signature.result]),
				[compiler.hl.HlFunction.HlInstruction.Return(signature.arguments.length)]);
		}];
		var bytes = HlWriter.encode(stubbed).flatten();
		var buffer = new StringBuf();
		// As little-endian 64-bit words, the byte order of every HashLink target: a C compiler reads an eighth of the numbers it
		// would read as bytes.
		buffer.add('const int hlc_image_size = ${bytes.length};\n');
		buffer.add("const unsigned long long hlc_image[] = {");
		var index = 0;
		while (index < bytes.length) {
			if (index % 128 == 0)
				buffer.add("\n");
			// The word's hexadecimal digits, most significant first, without leading zeros.
			buffer.add("0x");
			var started = false, nibble = 15;
			while (nibble >= 0) {
				var at = index + (nibble >> 1),
					value = at < bytes.length ? (bytes.get(at) >> ((nibble & 1) << 2)) & 15 : 0;
				if (started || value != 0 || nibble == 0) {
					buffer.addChar(value < 10 ? "0".code + value : "A".code + value - 10);
					started = true;
				}
				nibble--;
			}
			buffer.addChar(",".code);
			index += 8;
		}
		buffer.add("0};\n\n");
		buffer.add('const int hlc_slot_count = ${module.slotTypes.length};\n');
		buffer.add('const int hlc_entry = ${code.entryPoint};\n');
		buffer.add("void *hlc_functions[] = {");
		for (slot in 0...module.slotTypes.length)
			buffer.add((slot % 4 == 0 ? "\n\t" : " ")
				+ (module.slotTypes[slot] >= 0
				&& !module.native[slot] ? '(void*)${module.functionPointer(slot)},' : "NULL,"));
		buffer.add("\n\tNULL};\n\n");
		// By C name, for the stack capture: a function the C compiler inlined is a frame when it is a generated one.
		var named =
			[for (slot in 0...module.slotTypes.length) if (module.slotTypes[slot] >= 0 && !module.native[slot]) slot];
		named.sort((a, b) -> Reflect.compare(module.cNames[a], module.cNames[b]));
		buffer.add('const int hlc_function_name_count = ${named.length};\n');
		buffer.add("const struct { const char *name; int slot; } hlc_function_names[] = {");
		for (slot in named)
			buffer.add('\n\t{"${module.cNames[slot]}",$slot},');
		buffer.add("\n\t{NULL,-1}};\n\n");
		trampolines(buffer);
		// What the files name by stable names, each pointed at by the entry point before anything runs: the type descriptors, the
		// globals, the natives' pointers and the inline allocation descriptors.
		references(buffer, "hl_type", "type", [for (type in module.used.types.keys()) type],
			index -> module.typeNames[index]);
		references(buffer, "void", "global", [for (global in module.used.globals.keys()) global],
			index -> module.globalNames[index]);
		references(buffer, "void", "native", [for (slot in module.used.natives.keys()) slot],
			slot -> module.nativePointers[slot]);
		var allocations = [for (type in module.allocationTypes.keys()) type];
		allocations.sort((a, b) -> a - b);
		buffer.add('const int hlc_alloc_count = ${allocations.length};\n');
		buffer.add('const int hlc_alloc_types[] = {${allocations.concat([-1]).join(",")}};\n');
		for (type in allocations)
			buffer.add('hl_jit_alloc_data ${module.allocationNames[type]};\n');
		buffer.add("hl_jit_alloc_data *const hlc_alloc_refs[] = {");
		for (type in allocations)
			buffer.add('&${module.allocationNames[type]},');
		buffer.add("NULL};\n\n");
		// The C compiler's line table keeps a `#line` path relative to its working directory when the path is under it, so the
		// stack traces read the paths as written from here (`hlc_stack.c`).
		var paths = [for (path in module.sourcePaths.keys()) path];
		paths.sort(Reflect.compare);
		buffer.add('const int hlc_source_path_count = ${paths.length};\n');
		buffer.add("const char *const hlc_source_paths[] = {");
		for (path in paths)
			buffer.add('\n\t${HlcModule.quote(path)},');
		buffer.add("\n\tNULL};\n\n");
		buffer.add('const int hlc_global_count = ${module.globalOffsets.length};\n');
		buffer.add('const int hlc_global_offsets[] = {${module.globalOffsets.concat([-1]).join(",")}};\n\n');
		buffer.add("/* Object layouts: type, field count, then field index and offset pairs; -1 ends the list. */\n");
		buffer.add("const int hlc_object_layouts[] = {\n");
		for (index in 0...code.types.length)
			if (types.isObject(index)) {
				var fields = [for (field in types.fields(index)) if (!types.isVoid(field.type)) field];
				buffer.add('\t$index,${fields.length},');
				for (field in fields)
					buffer.add('${field.index},(int)offsetof(${types.structName(index)},f${field.index}),');
				buffer.add("\n");
			}
		buffer.add("\t-1};\n");
		return buffer.toString();
	}
}
