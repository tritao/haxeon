package compiler.backend.c;

import compiler.core.InternalError;
import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.incremental.HlSymbolTable;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrBodyBuilder;
import compiler.ir.IrTypeIds;

/** One generated C file: its path in the output directory and its text. */
typedef HlcFile = {
	final path:String;
	final content:String;
}

/**
 * The C sources of one HashLink assembly (docs/design/AOT_BACKEND.md): `hlc.h` with the object structs and function
 * prototypes, one file per Haxe source of the functions, and `image.c` with the module image the runtime builds its types
 * from, the slot table and the layout checks. `code`, `symbols` and `slots` are the assembly's; `program` is the program it
 * lowered.
 */
class HlcModule {
	public final code:HlCode;
	public final symbols:HlSymbolTable;
	public final types:HlcTypes;
	public final globalOffsets:Array<Int>;
	public final i32:Int;
	public final f64:Int;
	public final bool:Int;
	public final dyn:Int;
	public final typeRef:Int;

	final program:IrProgram;
	final slots:Map<String, Int>;
	final slotTypes:Array<Int> = [];
	final slotNames:Array<String> = [];
	final cNames:Array<String> = [];
	final native:Array<Bool> = [];
	final objects:Map<String, IrObject> = [];

	/** The program's objects as `HlLower`'s analyses read them. */
	public final view:compiler.hl.lower.HlLoweringView;

	public function new(code:HlCode, symbols:HlSymbolTable, program:IrProgram, slots:Map<String, Int>) {
		this.code = code;
		this.symbols = symbols;
		this.program = program;
		this.slots = slots;
		types = new HlcTypes(code);
		i32 = symbols.internType(IrType.I32);
		f64 = symbols.internType(IrType.F64);
		bool = symbols.internType(IrType.Bool);
		dyn = symbols.internType(IrType.Dyn);
		typeRef = symbols.internType(IrType.TypeRef);
		for (object in program.objects)
			objects.set(object.name, object);
		view = new compiler.hl.lower.HlLoweringView([], objects);
		for (fn in code.functions)
			place(fn.functionIndex, fn.type, false);
		for (entry in code.natives)
			place(entry.functionIndex, entry.type, true);
		for (name => slot in slots)
			if (slot < slotNames.length)
				slotNames[slot] = name;
		var used:Map<String, Bool> = [];
		for (slot in 0...slotTypes.length) {
			var name = slotNames[slot] == null ? 'slot$slot' : slotNames[slot],
				cName = "hx_" + identifier(name);
			if (used.exists(cName))
				cName += "_" + slot;
			used.set(cName, true);
			cNames[slot] = cName;
		}
		globalOffsets = types.globalOffsets();
	}

	function place(slot:Int, type:Int, isNative:Bool):Void {
		while (slotTypes.length <= slot) {
			slotTypes.push(-1);
			slotNames.push(null);
			native.push(false);
		}
		slotTypes[slot] = type;
		native[slot] = isNative;
	}

	/** A C identifier for a Haxe name. */
	public static function identifier(name:String):String {
		var buffer = new StringBuf();
		for (index in 0...name.length) {
			var code = StringTools.fastCodeAt(name, index);
			var valid = (code >= "a".code && code <= "z".code) || (code >= "A".code && code <= "Z".code)
				|| (code >= "0".code && code <= "9".code) || code == "_".code;
			buffer.addChar(valid ? code : "_".code);
		}
		return buffer.toString();
	}

	/** A C string literal of `text`, for `#line` and messages. */
	public static function quote(text:String):String {
		var buffer = new StringBuf();
		buffer.addChar('"'.code);
		for (index in 0...text.length) {
			var code = StringTools.fastCodeAt(text, index);
			if (code == '"'.code || code == "\\".code) {
				buffer.addChar("\\".code);
				buffer.addChar(code);
			} else if (code < 32 || code > 126)
				buffer.add("\\" + StringTools.hex(code >> 6 & 7) + StringTools.hex(code >> 3 & 7)
					+ StringTools.hex(code & 7));
			else
				buffer.addChar(code);
		}
		buffer.addChar('"'.code);
		return buffer.toString();
	}

	public function requireSlot(name:String):Int {
		var slot = slots.get(name);
		if (slot == null || slot >= slotTypes.length || slotTypes[slot] < 0)
			throw new InternalError('C backend: no function slot for $name');
		return slot;
	}

	public inline function slotType(slot:Int):Int
		return slotTypes[slot];

	public function slotName(slot:Int):String
		return slotNames[slot] == null ? 'slot $slot' : slotNames[slot];

	public function slotArguments(slot:Int):Array<Int>
		return types.signature(slotTypes[slot]).arguments;

	public function slotArgument(slot:Int, index:Int):Int
		return slotArguments(slot)[index];

	public function slotResult(slot:Int):Int
		return types.signature(slotTypes[slot]).result;

	/** What a C call of slot `slot` calls: the function itself, or a native through the slot table the loader filled. */
	public function functionPointer(slot:Int):String {
		if (!native[slot])
			return cNames[slot];
		var signature = types.signature(slotTypes[slot]);
		var arguments = [for (type in signature.arguments) types.cType(type)];
		return '((${types.cType(signature.result)} (*)(${arguments.length == 0 ? "void" : arguments.join(",")}))hlc_slots[$slot])';
	}

	/** The C declarator of the function in slot `slot`, its parameters named `names` (or left unnamed). */
	public function prototype(slot:Int, ?names:Array<String>):String {
		var signature = types.signature(slotTypes[slot]);
		var parameters = [
			for (index in 0...signature.arguments.length)
				types.cType(signature.arguments[index]) + (names == null ? "" : " " + names[index])
		];
		return '${types.cType(signature.result)} ${cNames[slot]}(${parameters.length == 0 ? "void" : parameters.join(", ")})';
	}

	/** The function a value class's method `name` is, called directly as `HlLower` calls it; null for other receivers. */
	public function valueMethod(type:IrType, name:String):Null<String> {
		var object = switch type {
			case Obj(objectName): objects.get(objectName);
			default: null;
		};
		if (object == null || !object.isValue)
			return null;
		for (method in object.methods)
			if (method.name == name)
				return method.functionName.name;
		return null;
	}

	/** The native storage of field `name` of object type `type` or a base (`IrFieldStorage.scalar`), or null. */
	public function fieldStorage(type:IrType, name:String):Null<compiler.ir.Ir.IrScalarStorage> {
		var owner = switch type {
			case Obj(objectName): objects.get(objectName);
			default: null;
		};
		while (owner != null) {
			for (field in owner.fields)
				if (field.name == name)
					return compiler.ir.IrFieldStorage.scalar(field);
			owner = owner.base == null ? null : objects.get(Std.string(owner.base));
		}
		return null;
	}

	/** The slot of the function at prototype slot `index` of object type `type` or its nearest base that has it. */
	public function prototypeFunction(type:Int, index:Int):Int {
		var current = type;
		while (current >= 0)
			switch code.types[current] {
				case Object(_, base, _, _, methods, _):
					for (method in methods)
						if (method.prototype == index)
							return method.functionIndex;
					current = base;
				default:
					break;
			}
		throw new InternalError('C backend: no method at prototype slot $index of ${types.typeName(type)}');
	}

	/** Whether slot `slot` has the signature the runtime takes as an object's `__compare` (`hl_get_obj_rt`). */
	public function isCompare(slot:Int):Bool {
		var signature = types.signature(slotTypes[slot]);
		return signature.arguments.length == 2 && types.kind(signature.arguments[1]) == HlType.Dyn
			&& types.kind(signature.result) == HlType.I32;
	}

	/** Lowers every function of the program and writes the files. */
	public function emit():Array<HlcFile> {
		// The program's table: every body of a program shares one (`IrStageHooks`), so one lowered here reads its ids as the rest.
		var lowering = new HlcFunctionLower(this),
			bodyTypes = IrTypeIds.ofFunctions(program.functions),
			builder = new IrBodyBuilder(new IrTypeIds()),
			files:Map<String, StringBuf> = [],
			fileOrder:Array<String> = [];
		var functions = [for (fn in program.functions) if (slots.exists(fn.name) && !native[slots.get(fn.name)]) fn];
		functions.sort((a, b) -> slots.get(a.name) - slots.get(b.name));
		var defined:Map<Int, Bool> = [];
		var bodies = [for (fn in functions) fn.bodyIn(bodyTypes, builder)];
		var fileNames = sourceFiles(bodies);
		for (index in 0...functions.length) {
			var body = bodies[index], slot = slots.get(functions[index].name), file = fileNames[index];
			var buffer = files.get(file);
			if (buffer == null) {
				buffer = new StringBuf();
				buffer.add('#include "hlc.h"\n\n');
				files.set(file, buffer);
				fileOrder.push(file);
			}
			try
				lowering.lower(body, slot, buffer)
			catch (error:HlcFunctionLower.HlcUnsupported)
				throw error
			catch (error:InternalError)
				throw new InternalError('C backend, lowering ${body.name}: ${error.message}');
			defined.set(slot, true);
		}
		for (slot in 0...slotTypes.length)
			if (slotTypes[slot] >= 0 && !native[slot] && !defined.exists(slot))
				throw new InternalError('C backend: slot $slot (${slotName(slot)}) has no IR function');
		// The header comes last: lowering may intern types (a cast's target) that the structs and the image must have.
		var result:Array<HlcFile> = [{path: "hlc.h", content: header()}];
		fileOrder.sort(Reflect.compare);
		for (file in fileOrder)
			result.push({path: file, content: files.get(file).toString()});
		result.push({path: "image.c", content: image()});
		return result;
	}

	/** Each function's file: the Haxe source most of its rows come from, so functions group by module. */
	function sourceFiles(bodies:Array<compiler.ir.IrBody>):Array<String> {
		var paths:Array<String> = [];
		for (body in bodies) {
			var counts:Map<String, Int> = [], best = "", bestCount = 0;
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var location = body.provenance(row).location;
					if (location != null) {
						var count = (counts.exists(location.path) ? counts.get(location.path) : 0) + 1;
						counts.set(location.path, count);
						if (count > bestCount || count == bestCount && location.path < best) {
							best = location.path;
							bestCount = count;
						}
					}
					row = body.nextRow(row);
				}
			}
			paths.push(best);
		}
		var distinct = [for (path in paths) path => true], names:Map<String, String> = [], taken:Map<String, Bool> = [];
		var sorted = [for (path in distinct.keys()) path];
		sorted.sort(Reflect.compare);
		for (path in sorted) {
			var base = path == "" ? "generated" : haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(path));
			var name = identifier(base), suffix = 1;
			while (taken.exists(name.toLowerCase()) || name == "image" || name == "hlc")
				name = identifier(base) + "_" + (++suffix);
			taken.set(name.toLowerCase(), true);
			names.set(path, name + ".c");
		}
		return [for (path in paths) names.get(path)];
	}

	function header():String {
		var buffer = new StringBuf();
		buffer.add("/* Generated by Haxeon's C backend (docs/design/AOT_BACKEND.md). */\n");
		buffer.add("#ifndef HLC_GENERATED_H\n#define HLC_GENERATED_H\n");
		buffer.add("#include <math.h>\n#include <string.h>\n#include <stddef.h>\n#include <hl.h>\n\n");
		buffer.add("#if defined(__GNUC__)\n");
		buffer.add("#pragma GCC diagnostic ignored \"-Wunused-label\"\n");
		buffer.add("#pragma GCC diagnostic ignored \"-Wunused-variable\"\n");
		buffer.add("#pragma GCC diagnostic ignored \"-Wunused-but-set-variable\"\n");
		buffer.add("#endif\n\n");
		buffer.add("extern hl_type *hlc_types;\nextern unsigned char *hlc_globals;\nextern void **hlc_slots;\n");
		buffer.add("void hl_jit_null_field_access( int fhash );\n");
		buffer.add("static inline double hlc_f64( unsigned int high, unsigned int low ) {\n");
		buffer.add("\tunsigned long long bits = ((unsigned long long)high << 32) | low; double value;\n");
		buffer.add("\tmemcpy(&value,&bits,sizeof(value)); return value;\n}\n\n");
		types.structDeclarations(buffer);
		buffer.add("\n");
		for (slot in 0...slotTypes.length)
			if (slotTypes[slot] >= 0 && !native[slot])
				buffer.add('${prototype(slot)}; /* ${slotName(slot)} */\n');
		buffer.add("\n#endif\n");
		return buffer.toString();
	}

	/**
	 * The module image: this module with every function body a stub, which the runtime decodes into its types, globals,
	 * natives and constants (`hl_code_read`, `hl_module_init`) before the slots are pointed at the C functions; the slot table;
	 * and the layouts the C code assumes, which the runtime checks against its own before running anything.
	 */
	function image():String {
		var stubbed = new HlCode();
		stubbed.ints = code.ints;
		stubbed.floats = code.floats;
		stubbed.strings = code.strings;
		stubbed.types = code.types;
		stubbed.globals = code.globals;
		stubbed.natives = code.natives;
		stubbed.constants = code.constants;
		stubbed.entryPoint = code.entryPoint;
		stubbed.functions = [for (fn in code.functions) {
			var signature = types.signature(fn.type);
			new HlFunction(fn.type, fn.functionIndex, signature.arguments.concat([signature.result]),
				[compiler.hl.HlFunction.HlInstruction.Return(signature.arguments.length)]);
		}];
		var bytes = HlWriter.encode(stubbed).flatten();
		var buffer = new StringBuf();
		buffer.add('#include "hlc.h"\n\n');
		buffer.add('const int hlc_image_size = ${bytes.length};\n');
		buffer.add("const unsigned char hlc_image[] = {");
		for (index in 0...bytes.length) {
			if (index % 32 == 0)
				buffer.add("\n");
			buffer.add(bytes.get(index));
			buffer.add(",");
		}
		buffer.add("0};\n\n");
		buffer.add('const int hlc_slot_count = ${slotTypes.length};\n');
		buffer.add('const int hlc_entry = ${code.entryPoint};\n');
		buffer.add("void *hlc_functions[] = {");
		for (slot in 0...slotTypes.length)
			buffer.add((slot % 4 == 0 ? "\n\t" : " ")
				+ (slotTypes[slot] >= 0 && !native[slot] ? '(void*)${cNames[slot]},' : "NULL,"));
		buffer.add("\n\tNULL};\n\n");
		buffer.add('const int hlc_global_count = ${globalOffsets.length};\n');
		buffer.add('const int hlc_global_offsets[] = {${globalOffsets.concat([-1]).join(",")}};\n\n');
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
