import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.SourceProvenance.Located;
import compiler.ir.passes.nullability.IrStaticNullChecks;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFunctionVersions;
import compiler.ir.reuse.IrStageMemo.IrLineage;
import compiler.ir.reuse.IrStageMemo.IrStageMemos;

/**
 * The static null-check stage's memo must give an unchanged function the same object every build, and the same result as a run
 * with no memo, while what the rewrite reads (whether initialization reaches the function, whether a receiver is a value) holds.
 */
class StaticNullCheckReuseMain {
	static final memos = new IrStageMemos(new IrFunctionVersions());
	static final types = new IrTypeIds();

	/** By name, the generator's function and its version: a new object takes a new version. */
	static final generated:Map<String, {fn:IrFunction, version:Int}> = [];

	/** One build of the stage in the session, past the encode point, with `--check-reuse`. */
	static function build(functions:Array<IrFunction>, ?objects:Array<IrObject>):Array<IrFunction> {
		for (fn in functions) {
			var known = generated.get(fn.name);
			if (known == null || known.fn != fn) {
				fn.bodyIn(types);
				fn.freezeBody();
				generated.set(fn.name, {fn: fn, version: memos.versions.next()});
			}
		}
		var input = functions.copy();
		var lineage = IrLineage.start(memos, input, name -> {
			var known = generated.get(name);
			known == null ? 0 : known.version;
		}, true);
		lineage.enterBodies();
		return IrFunctionStages.run(IrStaticNullChecks.STAGE,
			new IrStaticNullChecks(objects, types, null, lineage, true),
			input, lineage, true);
	}

	static function expect(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	// A function that reads a field of a static, so it gets a check and a shared helper.
	static function reader(name:String, global:String, offset:Int):IrFunction {
		var b = new IrBuilder();
		var g = new IrValue(100, "g", Obj("Box"));
		b.blocks[0].instructions.push(new Located(GlobalGet(g, global), SourceProvenance.generated("test")));
		var v = b.fieldGet(g, "v", I32);
		b.returnValue(b.add(v, b.constInt(offset)));
		return new IrFunction(name, b.arguments, I32, b.blocks, Ordinary);
	}

	static function caller(name:String, callees:Array<String>):IrFunction {
		var b = new IrBuilder();
		for (callee in callees)
			b.call(callee, [], I32);
		b.returnValue(b.constVoid());
		return new IrFunction(name, b.arguments, Void, b.blocks, Ordinary);
	}

	static function program(offset:Int):Array<IrFunction>
		return [
			caller("__init", ["readA", "readB"]),
			reader("readA", "S.a", offset),
			reader("readB", "S.b", 2),
			reader("unreached", "S.a", 3)
		];

	static function bytes(fn:IrFunction):String
		return IrFunctionStateCodec.encode(fn).toHex();

	static function sameAsUncached(cached:Array<IrFunction>, input:Array<IrFunction>):Void {
		var plain = IrStaticNullChecks.run(input, null, types);
		expect(plain.length == cached.length, "a memoized run returns the same functions as a run without a memo");
		for (index in 0...plain.length) {
			expect(plain[index].name == cached[index].name, "a memoized run keeps the order");
			expect(bytes(plain[index]) == bytes(cached[index]),
				'a memoized run builds the same ${plain[index].name} as a run without a memo');
		}
	}

	static function byName(functions:Array<IrFunction>):Map<String, IrFunction>
		return [for (fn in functions) fn.name => fn];

	static function main():Void {
		var sources = program(1);
		var first = build(sources);
		expect(byName(first).exists("__static$nonnull$S.a"), "a read of a static gets its null-check helper");
		sameAsUncached(first, sources);
		// The next build is given the unchanged functions as the same objects; nothing is made again.
		var again = build(sources);
		for (index in 0...first.length)
			expect(first[index] == again[index], 'an unchanged ${first[index].name} keeps its identity');
		sameAsUncached(again, sources);
		// Editing one function changes that function and nothing else.
		var edited = sources.copy();
		edited[1] = reader("readA", "S.a", 9);
		var changed = build(edited);
		var before = byName(again), after = byName(changed);
		expect(after.get("readA") != before.get("readA"), "an edited function is rebuilt");
		for (name in ["__init", "readB", "unreached", "__static$nonnull$S.a", "__static$nonnull$S.b"])
			expect(after.get(name) == before.get(name), 'an unedited $name keeps its identity');
		sameAsUncached(changed, edited);
		// A function that stops being reachable from initialization comes back unchanged, though it was not edited.
		var unreachable = edited.copy();
		unreachable[0] = caller("__init", ["readB"]);
		var pruned = byName(build(unreachable));
		expect(pruned.get("readA") == unreachable[1], "an unreachable function is passed through");
		expect(!pruned.exists("__static$nonnull$S.a"), "a check nothing asks for is dropped");
		sameAsUncached(build(unreachable), unreachable);
		sources = edited;
		// A value static must keep the initialization guard without boxing on every field read.
		var valueObject:IrObject = {
			name: "Box",
			isValue: true,
			base: null,
			interfaces: [],
			fields: [{name: "v", type: I32}],
			methods: []
		};
		var valueChecked = build(sources, [valueObject]);
		var read = byName(valueChecked).get("readA"), boxed = false, typedHelper = false;
		for (block in read.blocks) for (located in block.instructions) switch located.value {
			case ToDyn(_, _): boxed = true;
			case Call(_, name, args) if (StringTools.startsWith(name.name, "$static$nonnull$value$")
				&& Type.enumEq(args[0].type, Obj("Box"))):
				typedHelper = true;
			default:
		}
		expect(!boxed && typedHelper, "value static checks keep their typed reference without a dynamic box");
		var referenceObject:IrObject = {
			name: "Box",
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "v", type: I32}],
			methods: []
		};
		var referenceChecked = build(sources, [referenceObject]);
		expect(byName(referenceChecked).exists("__static$nonnull$S.a"),
			"changing a value to a reference rewrites the functions that read one");
		var b = new IrBuilder(), dst = new IrValue(100, "dst", Obj("Box")), src = new IrValue(101, "src", Obj("Box"));
		b.blocks[0].instructions.push(new Located(GlobalGet(dst, "S.dst"), SourceProvenance.generated("test")));
		b.blocks[0].instructions.push(new Located(GlobalGet(src, "S.src"), SourceProvenance.generated("test")));
		b.call(compiler.ir.passes.nullability.IrOptionalFieldStorage.copyName("Box", "v", "Box", "v"), [dst, src],
			Void);
		b.returnValue(b.constVoid());
		var init = new IrFunction("__init", [], Void, b.blocks, Ordinary),
			checked = byName(IrStaticNullChecks.run([init], [referenceObject])).get("__init");
		var checks:Array<String> = [];
		for (block in checked.blocks) for (located in block.instructions) switch located.value {
			case Call(_, name, _) if (StringTools.startsWith(name.name, "__static$nonnull$")): checks.push(name.name);
			default:
		}
		expect(checks.join(",") == "__static$nonnull$S.src,__static$nonnull$S.dst",
			"optional copies check source before destination");
		// Names that come and go: the lineage frees the slots of names gone for a build, with their memo entries, and gives them
		// to new names, whose builds must not read what the old names left.
		var distinct = 0;
		for (round in 0...8) {
			var renamed = [
				caller("__init", ['readA$round', 'readB$round']),
				reader('readA$round', 'S.a$round', round),
				reader('readB$round', 'S.b', 2),
				reader('unreached$round', 'S.a$round', 3)
			];
			distinct += 5;
			sameAsUncached(build(renamed), renamed);
		}
		expect(memos.lineage.slots.count < distinct, "the slots of names that are gone are given to new names");
		sameAsUncached(build(sources), sources);
		Sys.println("static null-check reuse OK");
	}
}
