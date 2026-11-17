package tools.dev;

import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlModuleReader;
import compiler.hl.HlModuleReader.HlModule;
import compiler.hl.HlModuleReader.HlModuleFunction;
import compiler.hl.HlOpcodeSchema;
import compiler.hl.HlWriter;
import sys.io.File;

/**
 * `haxeon dev hl-stat MODULE [--ops [N]] [--top N] [--dump NAME [--index I]] [--around OPCODE] [--sections]`: what a
 * HashLink module is made of, read with HlModuleReader. Two modules side by side (one stock Haxe wrote, one this compiler
 * wrote) answer most "why is ours bigger or slower to load" questions; HashLink compiles every instruction when it loads a
 * module, so instruction counts are start-up time.
 *
 *   (no option)          the bytes of each part of the module, and its function, instruction and register counts
 *   --ops [N]            the N most frequent opcodes (30)
 *   --top N              the N largest functions, with instruction and register counts
 *   --dump NAME          one function's instructions, NAME as --top prints it; --index I picks one of several
 *   --around OPCODE      the opcodes before and after OPCODE (OSwitch or Switch), by count
 *   --sections           the debug sections and their sizes
 */
class HlStatCommand {
	public static function run(arguments:Array<String>):Int {
		if (arguments.length == 0 || StringTools.startsWith(arguments[0], "-")) {
			Sys.stderr()
				.writeString("usage: haxeon dev hl-stat MODULE [--ops [N]] [--top N] [--dump NAME [--index I]] [--around OPCODE] [--sections]\n");
			return 2;
		}
		var path = arguments[0], module = HlModuleReader.read(File.getBytes(path)), names = functionNames(module);
		function option(name:String):Null<String> {
			var at = arguments.indexOf(name);
			return at < 0 ? null : (at + 1 < arguments.length ? arguments[at + 1] : "");
		}
		var instructions = 0, registers = 0;
		for (fn in module.functions) {
			instructions += fn.instructions.length;
			registers += fn.registers.length;
		}
		var size = 0;
		for (part in module.sizes)
			size += part.bytes;
		Sys.println('${haxe.io.Path.withoutDirectory(path)}: HLB ${module.version}, ${size + 4} bytes, '
			+ '${module.functions.length} functions, $instructions instructions, $registers registers');
		for (part in module.sizes)
			Sys.println('  ${pad(part.name, 40)} ${leftPad(part.bytes, 10)}');
		if (arguments.indexOf("--ops") >= 0) {
			var count = Std.parseInt(option("--ops") ?? "") ?? 30, counts:Map<Int, Int> = [];
			for (fn in module.functions)
				for (instruction in fn.instructions)
					counts.set(instruction.opcode, (counts.get(instruction.opcode) ?? 0) + 1);
			var ranked = [for (opcode => n in counts) {
				opcode:opcode, n:n
			}];
			ranked.sort((a, b) -> b.n - a.n);
			for (entry in ranked.slice(0, count))
				Sys.println('  ${pad(opcodeName(entry.opcode), 18)} ${leftPad(entry.n, 9)}');
		}
		var top = option("--top");
		if (top != null) {
			var sorted = module.functions.copy();
			sorted.sort((a, b) -> b.bytes - a.bytes);
			for (fn in sorted.slice(0, Std.parseInt(top) ?? 10))
				Sys.println('  ${leftPad(fn.bytes, 8)} bytes ${leftPad(fn.instructions.length, 6)} instructions '
					+ '${leftPad(fn.registers.length, 5)} registers  ${name(names, fn)}');
		}
		var dump = option("--dump");
		if (dump != null) {
			var index = option("--index"), found = false;
			for (fn in module.functions)
				if (name(names, fn) == dump && (index == null || Std.string(fn.functionIndex) == index)) {
					found = true;
					Sys.println('function $dump (index ${fn.functionIndex}): ${fn.registers.length} registers, '
						+ '${fn.instructions.length} instructions');
					for (at in 0...fn.instructions.length) {
						var instruction = fn.instructions[at];
						Sys.println('  ${leftPad(at, 5)} ${pad(opcodeName(instruction.opcode).substr(1), 14)} ${instruction.operands}');
					}
				}
			if (!found) {
				Sys.stderr().writeString('No function named $dump\n');
				return 1;
			}
		}
		var around = option("--around");
		if (around != null) {
			var wanted = StringTools.startsWith(around, "O") ? around : "O" + around,
				before:Map<Int, Int> = [],
				after:Map<Int, Int> = [];
			for (fn in module.functions)
				for (at in 0...fn.instructions.length)
					if (opcodeName(fn.instructions[at].opcode) == wanted) {
						if (at > 0)
							before.set(fn.instructions[at - 1].opcode,
								(before.get(fn.instructions[at - 1].opcode) ?? 0) + 1);
						if (at + 1 < fn.instructions.length)
							after.set(fn.instructions[at + 1].opcode,
								(after.get(fn.instructions[at + 1].opcode) ?? 0) + 1);
					}
			Sys.println('  before $wanted: ${ranking(before)}');
			Sys.println('  after  $wanted: ${ranking(after)}');
		}
		if (arguments.indexOf("--sections") >= 0)
			for (section in module.sections)
				Sys.println('  ${pad(sectionName(section.kind), 22)} version ${section.version}, flags ${section.flags}: '
					+ '${section.payload.length} bytes');
		return 0;
	}

	/**
	 * Each function's name: from the function identity section where the module has one (the names the VM's traces use),
	 * else `Owner.member` from class prototypes and from bindings (static methods), whose field index counts the fields of
	 * every base class first.
	 */
	static function functionNames(module:HlModule):Map<Int, String> {
		var names:Map<Int, String> = [];
		for (section in module.sections)
			if (section.kind == HlWriter.FUNCTION_IDENTITIES)
				for (identity in HlModuleReader.functionIdentities(section.payload))
					names.set(identity.functionIndex, identity.qualifiedName);
		function allFields(type:Int):Array<String>
			return switch module.types[type] {
				case Object(_, base, _, fields, _, _): (base >= 0 ? allFields(base) : []).concat([
					for (field in fields) module.strings[field.name]
				]);
				case Structure(_, _, fields, _, _): [for (field in fields) module.strings[field.name]];
				default: [];
			};
		for (type in 0...module.types.length)
			switch module.types[type] {
				case Object(name, _, _, _, methods, bindings), Structure(name, _, _, methods, bindings):
					var owner = StringTools.replace(module.strings[name], "$", ""), fields = allFields(type);
					for (method in methods)
						if (!names.exists(method.functionIndex))
							names.set(method.functionIndex, owner + "." + module.strings[method.name]);
					var at = 0;
					while (at + 1 < bindings.length) {
						if (!names.exists(bindings[at + 1]))
							names.set(bindings[at + 1],
								owner + "." + (bindings[at] < fields.length ? fields[bindings[at]] : "<binding>"));
						at += 2;
					}
				default:
			}
		return names;
	}

	static function name(names:Map<Int, String>, fn:HlModuleFunction):String
		return names.get(fn.functionIndex) ?? '<function ${fn.functionIndex}>';

	static function opcodeName(opcode:Int):String
		return HlOpcodeSchema.name(opcode) ?? 'O#$opcode';

	static function sectionName(kind:Int):String
		return switch kind {
			case HlWriter.FUNCTION_IDENTITIES: "function identities";
			case HlWriter.OPCODE_SOURCE_SPANS: "opcode source spans";
			case HlWriter.SOURCE_SNAPSHOTS: "source snapshots";
			default: 'kind $kind';
		};

	static function ranking(counts:Map<Int, Int>):String {
		var ranked = [for (opcode => n in counts) {
			opcode:opcode, n:n
		}];
		ranked.sort((a, b) -> b.n - a.n);
		return [for (entry in ranked.slice(0, 12)) opcodeName(entry.opcode).substr(1) + " " + entry.n].join(", ");
	}

	static function pad(text:String, width:Int):String
		return StringTools.rpad(text, " ", width);

	static function leftPad(value:Int, width:Int):String
		return StringTools.lpad(Std.string(value), " ", width);
}
