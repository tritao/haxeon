import compiler.Frontend;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlModuleReader;
import compiler.hl.HlOpcodeSchema;
import compiler.hl.HlWriter;
import compiler.hl.lower.HlLower;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

/**
 * HlWriter checked against an independent decoder: a module written from a lowered program reads back (HlModuleReader, which
 * follows the VM's loader) to the tables, types, functions, instructions and debug lines it was written from. A module stock
 * Haxe wrote reads to its last byte too, so the reader follows the VM, not this writer.
 */
class HlModuleRoundTripMain {
	static function main():Void {
		var code =
			HlLower.lower(Frontend.compile("
			enum Shape { Circle(radius:Float); Square(side:Int); Empty; }
			class Counter {
				public var count = 0;
				public function new() {}
				public function add(by:Int):Int return count += by;
			}
			@:noInline function area(shape:Shape):Float
				return switch shape { case Circle(r): 3.5 * r * r; case Square(s): s * s; case Empty: 0; }
			function main():Int {
				var counter = new Counter(), names = ['a', 'bb', 'ccc'];
				for (name in names) counter.add(name.length);
				var total = 0.0;
				try { total = area(Circle(2.0)) + area(Square(3)); if (total > 100) throw 'big'; } catch (e:String) total = -1;
				var twice = (x:Int) -> x * 2;
				return counter.count == 6 && total == 23 && twice(21) == 42 ? 42 : 1;
			}
		"));
		var bytes = HlWriter.encode(code).flatten(), module = HlModuleReader.read(bytes);
		expect(module.strings.join("\n") == code.strings.join("\n"), "the string table reads back");
		expect(module.ints.join(",") == code.ints.join(","), "the integer table reads back");
		expect(module.floats.join(",") == code.floats.join(","), "the float table reads back");
		expect(module.globals.join(",") == code.globals.join(","), "the global types read back");
		expect(module.entryPoint == code.entryPoint, "the entry point reads back");
		expect(module.types.length == code.types.length, "every type reads back");
		for (index in 0...code.types.length)
			expect(sameType(module.types[index], code.types[index]), 'type $index reads back as written');
		// The writer adds the function identities, which name the functions.
		expect(module.sections.length == code.debugSections.length + 1, "every debug section reads back");
		expect(module.functions.length == code.functions.length, "every function reads back");
		var instructions = 0, lines = 0;
		for (index in 0...code.functions.length) {
			var written = code.functions[index],
				read = module.functions[index],
				positions = HlWriter.layout(written.opcodes);
			expect(read.type == written.type && read.functionIndex == written.functionIndex,
				'function ${written.functionIndex} keeps its type and index');
			expect(read.registers.join(",") == written.registers.join(","),
				'function ${written.functionIndex} keeps its registers');
			expect(read.instructions.length == positions[written.opcodes.length],
				'function ${written.functionIndex} has as many instructions as its layout');
			for (instruction in read.instructions) {
				HlOpcodeSchema.validate(instruction.opcode, instruction.operands);
				instructions++;
			}
			if (written.debugLocations.length > 0)
				for (at in 0...written.opcodes.length)
					if (positions[at + 1] != positions[at]) {
						var location = written.debugLocations[at];
						expect(read.lines[positions[at]].line == code.sources.line(location.anchor) + location.line,
							'function ${written.functionIndex}, instruction ${positions[at]}: its debug line reads back');
						lines++;
					}
		}
		expect(lines > 0, "the module has debug lines to check");
		Sys.println('PASS: a written module reads back: ${module.functions.length} functions, $instructions instructions, $lines lines');

		// A module stock Haxe wrote, an older HLB version with opcodes this compiler does not emit.
		var work = Path.join([Sys.getEnv("TMPDIR") ?? "/tmp", 'haxeon-module-reader-${Std.random(0x7fffffff)}']);
		FileSystem.createDirectory(work);
		File.saveContent(Path.join([work, "Main.hx"]),
			"class Main { static function main() { var m = new Map<String, Int>(); m['x'] = 1; try { trace(m['x'] + Std.random(2)); } catch (e:Dynamic) {} } }");
		var haxe = Path.join([Sys.getCwd(), ".tools", "haxe", Sys.systemName() == "Windows" ? "haxe.exe" : "haxe"]),
			output = Path.join([work, "main.hl"]);
		var status = Sys.command(haxe, ["-cp", work, "-main", "Main", "-hl", output]);
		expect(status == 0, "stock Haxe builds the probe");
		var stock = HlModuleReader.read(File.getBytes(output));
		expect(stock.functions.length > 100 && stock.types.length > 50, "stock Haxe's module reads to its last byte");
		FileSystem.deleteFile(output);
		FileSystem.deleteFile(Path.join([work, "Main.hx"]));
		FileSystem.deleteDirectory(work);
		Sys.println('PASS: a module stock Haxe wrote (HLB ${stock.version}) reads: ${stock.functions.length} functions');
	}

	/** Two type definitions are the same, field by field (anonymous records compare by their fields, not their order). */
	static function sameType(left:HlTypeDef, right:HlTypeDef):Bool
		return switch [left, right] {
			case [Object(n1, b1, g1, f1, m1, k1), Object(n2, b2, g2, f2, m2, k2)]:
				n1 == n2 && b1 == b2 && g1 == g2 && fields(f1) == fields(f2) && methods(m1) == methods(m2)
					&& k1.join(",") == k2.join(",");
			case [Structure(n1, g1, f1, m1, k1), Structure(n2, g2, f2, m2, k2)]:
				n1 == n2 && g1 == g2 && fields(f1) == fields(f2) && methods(m1) == methods(m2)
					&& k1.join(",") == k2.join(",");
			case [Virtual(n1, f1), Virtual(n2, f2)]: n1 == n2 && fields(f1) == fields(f2);
			case [Enum(n1, g1, c1), Enum(n2, g2, c2)]:
				n1 == n2 && g1 == g2 && [for (c in c1) c.name + ":" + c.params.join(",")].join(";") == [
					for (c in c2) c.name + ":" + c.params.join(",")
				].join(";");
			case [Function(a1, r1), Function(a2, r2)]: a1.join(",") == a2.join(",") && r1 == r2;
			case [EnumTag(b1, c1), EnumTag(b2, c2)]: b1 == b2 && c1.join(",") == c2.join(",");
			case [Parameterized(k1, p1), Parameterized(k2, p2)]: k1 == k2 && p1 == p2;
			case [Abstract(n1), Abstract(n2)]: n1 == n2;
			case [Simple(k1), Simple(k2)]: k1 == k2;
			default: false;
		}

	static function fields(list:Array<{
		final name:Int;
		final type:Int;
	}>):String return [for (field in list) field.name + ":" + field.type].join(",");

	static function methods(list:Array<{
		final name:Int;
		final functionIndex:Int;
		final prototype:Int;
	}>):String return [for (method in list) method.name + ":" + method.functionIndex + ":"
		+ method.prototype].join(",");

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}
