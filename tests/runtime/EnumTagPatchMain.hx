import compiler.Compiler;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrEnum;
import compiler.hl.incremental.HlSymbolTable;
import compiler.hl.HlWriter;
import compiler.hl.persistence.HlSymbolStateCodec;
import compiler.hl.persistence.HlTypeDefStateCodec;
import compiler.hl.HlCode.HlTypeDef;
import runtime.PatchSet;
import runtime.Runtime;

/** Scalar enum metadata survives symbol persistence and live body patches. */
@:access(compiler.hl.HlWriter)
class EnumTagPatchMain {
	static function source(version:Int):String
		return 'enum Mode { Off; On; }\n'
			+ 'enum Carrier { Wrap(mode:Mode); More(next:Carrier); }\n'
			+ 'class Holder { public var mode:Mode; public function new() mode=On; }\n'
			+ 'function make():Holder return new Holder();\n'
			+ 'function probe(value:Holder):Int {\n'
			+ ' var restored:Mode=cast Reflect.field(value,"mode"); if(restored!=On) return 1;\n'
			+ ' if(Std.string(Wrap(value.mode))!="Wrap(On)") return 2;\n'
			+ ' Reflect.setField(value,"mode",Off); if(value.mode!=Off) return 3;\n'
			+ ' Reflect.setField(value,"mode",On); return $version;\n}\n'
			+ 'function main():Int return probe(make());\n';

	static function main():Void {
		var compiler = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.update("Main.hx", source(41));
		var first = compiler.compile("Main");
		var symbols = new HlSymbolTable();
		var mode:IrEnum = {name: "Mode", cases: [{name: "Off", params: []}, {name: "On", params: []}]};
		symbols.reserveEnum(mode);
		symbols.internEnum(mode);
		// Completed boxed descriptors suffice even when no scalar descriptor has been interned yet.
		for (view in [symbols.copy(), symbols.fork(), HlSymbolStateCodec.restore(HlSymbolStateCodec.encode(symbols.exportState()))])
			view.internType(IrType.EnumTag("Mode"));
		var tagType = symbols.internType(IrType.EnumTag("Mode"));
		if (tagType == symbols.internType(IrType.I32))
			throw "HashLink erased the nominal tag type";
		var persisted = HlSymbolStateCodec.encode(symbols.exportState());
		var restored = HlSymbolStateCodec.restore(persisted);
		if (HlSymbolStateCodec.encode(restored.exportState()).compare(persisted) != 0)
			throw "Nominal enum type metadata lost during persistence";
		var boxedType = symbols.internType(IrType.Enum("Mode"));
		for (malformed in [HlTypeDef.EnumTag(symbols.internType(IrType.I32), [0, 1]),
			HlTypeDef.EnumTag(boxedType, []), HlTypeDef.EnumTag(boxedType, [0, symbols.globals.length])]) {
			var definitions = symbols.types.copy();
			definitions[tagType] = malformed;
			var rejected = false;
			try
				HlTypeDefStateCodec.decode(HlTypeDefStateCodec.encode(definitions), symbols.strings.length, symbols.globals.length)
			catch (_:Dynamic)
				rejected = true;
			if (!rejected)
				throw "Malformed scalar enum descriptor was accepted";
		}
		// Bypass the writer's verifier to exercise the VM reader on a forged cache-global index.
		var tagIndex = -1;
		for (i in 0...first.module.types.length)
			switch first.module.types[i] {
				case EnumTag(_, _): tagIndex = i;
				default:
			}
		if (tagIndex < 0) throw "Missing native scalar enum descriptor";
		var saved = first.module.types[tagIndex];
		switch saved {
			case EnumTag(boxed, globals):
				var badGlobals = globals.copy();
				badGlobals[0] = first.module.globals.length;
				first.module.types[tagIndex] = EnumTag(boxed, badGlobals);
			default: throw "Missing enum tag metadata";
		}
		var uncheckedWriter = new HlWriter();
		uncheckedWriter.writeCode(first.module);
		first.module.types[tagIndex] = saved;
		var directory = Sys.getEnv("TMPDIR");
		if (directory == null) directory = "out";
		var invalidPath = directory + "/invalid-enum-cache-" + Std.random(0x7fffffff) + ".hl";
		sys.io.File.saveBytes(invalidPath, uncheckedWriter.getBytes());
		var child = new sys.io.Process("scripts/hl", [invalidPath]);
		var output = child.stdout.readAll().toString(), error = child.stderr.readAll().toString(), status = child.exitCode();
		child.close();
		sys.FileSystem.deleteFile(invalidPath);
		if (status == 0 || (output + error).indexOf("Invalid scalar enum cache global") < 0)
			throw "VM did not reject a forged scalar enum cache global: " + output + error;
		var live = Runtime.load(HlWriter.encode(first.module), first.runtimeIdentity);
		var retained = Runtime.retainObject(live, first.functionIds.get("Main.make"));
		if (Runtime.callIntObject(live, first.functionIds.get("Main.probe"), retained) != 41)
			throw "Initial enum tag metadata failed";
		compiler.update("Main.hx", source(42));
		var changed = compiler.compile("Main");
		if (changed.requiresReload || changed.patchBytes == null)
			throw "A body patch changed scalar enum layout";
		Runtime.patchSet(live, new PatchSet(first.revision, changed.revision, changed.patchBytes, changed.changedFunctions));
		hl.Gc.major();
		if (Runtime.callIntObject(live, changed.functionIds.get("Main.probe"), retained) != 42)
			throw "A retained object lost scalar enum metadata after patching";
		var fresh = Runtime.load(HlWriter.encode(changed.module), changed.runtimeIdentity);
		if (Runtime.callInt(fresh, changed.functionIds.get("main")) != 42)
			throw "Reloaded enum tag metadata failed";
		retained.release();
		Runtime.dispose(live);
		Runtime.dispose(fresh);
		Sys.println("PASS: scalar enum metadata, cached boxes and retained fields survive persistence, patching and reload");
	}
}
