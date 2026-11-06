import compiler.ir.Ir;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueLaneLayout;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.IrVerifier;

/** Representation decisions must agree across targets, even where pointers and scalar words differ. */
class InlineEnumLayoutMain {
	static function declaration(name:String, large:Array<IrType>, ?small:Array<IrType>):IrEnum
		return {name: name, cases: [{name: "Small", params: small == null ? [] : small}, {name: "Large", params: large}]};

	static function pointerObjects(bits:Int):Array<IrObject> {
		var size = Std.int(bits / 8);
		return [for (count in [8, 9]) {
			name: count == 8 ? "EightPointers" : "NinePointers", isValue: true, base: null, interfaces: [], methods: [],
			nativeLayout: {target: bits == 64 ? IrInlineEnumLayout.CANONICAL_ABI : "wasm32-wasi", size: count * size, alignment: size},
			fields: [for (index in 0...count) {name: 'pointer$index', type: RawPtr,
				nativeLayout: {offset: index * size, size: size, alignment: size, signed: false, inlineRecord: false}}]
		}];
	}

	static function main():Void {
		var enums:Array<IrEnum> = [
			{name: "Paint", cases: [{name: "Empty", params: []}, {name: "Rgb", params: [I32, I32, I32]},
				{name: "Wide", params: [F64, Bytes]}]},
			declaration("Wrapped", [Enum("Paint")]),
			declaration("StructWrapped", [Obj("Holder")]),
			declaration("Containers", [Array(Enum("Paint")), Function([Enum("Paint")], Enum("Paint"))]),
			declaration("Optional", [Nullable(Obj("OptionalFields"))]),
			declaration("Recursive", [Enum("Recursive")]),
			declaration("RecursiveArray", [Array(Enum("RecursiveArray"))]),
			declaration("MutualA", [Enum("MutualB")]), declaration("MutualB", [Enum("MutualA")]),
			declaration("BoxedChild", [Enum("Recursive")]),
			declaration("EightWords", [for (_ in 0...16) I32]),
			declaration("NineWords", [for (_ in 0...17) I32]),
			declaration("Balanced", [for (_ in 0...10) I64], [for (_ in 0...5) I64]),
			declaration("Unbalanced", [for (_ in 0...11) I64], [for (_ in 0...5) I64]),
			declaration("EightReferences", [for (_ in 0...8) Bytes]),
			declaration("NineReferences", [for (_ in 0...9) Bytes]),
			declaration("Pointers", [for (_ in 0...9) RawPtr]),
			declaration("FlatPointers", [Obj("NinePointers")]),
			declaration("SmallFlatPointers", [Obj("EightPointers")]),
			{name: "SinglePayload", cases: [{name: "Some", params: [I32]}]}
		];
		var objects:Array<IrObject> = [
			{name: "Holder", isValue: true, base: null, interfaces: [], methods: [],
				fields: [{name: "paint", type: Enum("Paint")}, {name: "count", type: I32}]},
			{name: "OptionalFields", isValue: true, base: null, interfaces: [], methods: [],
				fields: [{name: "number", type: Nullable(I32)}, {name: "owner", type: Bytes}]}
		];
		for (target in [HashLink, Wasm32, WasmGc]) {
			var bits = target == HashLink ? 64 : 32;
			var physicalObjects = objects.concat(pointerObjects(bits));
			var layout = new IrInlineEnumLayout(enums, physicalObjects, bits, target, objects.concat(pointerObjects(64)));
			var paint = layout.shape("Paint"), wrapped = layout.shape("Wrapped");
			if (paint == null || paint.wordBits != 64 || paint.scalarWords != 2 || paint.references != 1)
				throw "cases must overlap their scalar and reference payloads";
			if (paint.cases[1].payload.slots[1].bitOffset != 32 || paint.cases[2].payload.references != 1)
				throw "all cases must use the shared scalar word width";
			if (wrapped == null || wrapped.references != 1 || wrapped.scalarWords != 3)
				throw "nested enums must include the tag and complete payload";
			var holder = layout.shape("StructWrapped"), mapped = layout.mappedObject("Holder");
			if (holder == null || holder.references != 1 || mapped == null
				|| !IrVerifier.sameType(mapped.fields[0].type, Obj(paint.valueObject.name)))
				throw "struct payloads must preserve their nominal name and map nested enum fields";
			var containers = layout.shape("Containers"), value:IrType = Obj(paint.valueObject.name);
			if (containers == null || containers.references != 2
				|| !IrVerifier.sameType(containers.cases[1].parameters[0], Array(Enum("Paint")))
				|| !IrVerifier.sameType(containers.cases[1].parameters[1], Function([Enum("Paint")], Enum("Paint"))))
				throw "reference payloads must retain their semantic array and closure types";
			var optional = layout.shape("Optional");
			if (optional == null || optional.references != 1 || optional.cases[1].payload.slots.length != 4
				|| !optional.cases[1].payload.slots[0].isPresence || !optional.cases[1].payload.slots[1].isPresence)
				throw "nested nullability must keep distinct presence bits and traced references";
			if (layout.shape("EightWords") == null || layout.shape("Balanced") == null || layout.shape("EightReferences") == null || layout.shape("SmallFlatPointers") == null)
				throw "the inline cutoff must count 64-bit scalar words plus references";
			for (name in ["Recursive", "RecursiveArray", "MutualA", "MutualB", "NineWords", "Unbalanced", "NineReferences", "Pointers", "FlatPointers"])
				if (layout.shape(name) != null) throw 'Expected boxed representation for $name on $target';
			var single = layout.shape("SinglePayload");
			if (single == null || single.wordBits != 32 || single.scalarWords != 1 || single.references != 0
				|| single.valueObject.fields.length != 2)
				throw "a one-case scalar payload must use the same tag and lane layout";
			if (target != HashLink) {
				var missingCanonical = new IrInlineEnumLayout(enums, physicalObjects, bits, target), error = "";
				try missingCanonical.shape("FlatPointers") catch (caught:Dynamic) error = Std.string(caught);
				if (error.indexOf(IrInlineEnumLayout.CANONICAL_ABI) < 0 || error.indexOf("NinePointers") < 0)
					throw "target-specific Flat offsets must never determine enum eligibility";
			}
			var error = "";
			try new IrInlineEnumLayout(enums, physicalObjects, bits, target, objects) catch (caught:Dynamic) error = Std.string(caught);
			if (error != 'Missing canonical value object "EightPointers" for inline enum classification')
				throw "a missing canonical struct must not silently become a reference leaf";
			var boxed = layout.shape("BoxedChild");
			if (boxed == null || boxed.scalarWords != 0 || boxed.references != 1)
				throw "a boxed recursive child belongs in a traced reference slot";
			var generated = layout.generatedObjects(), names = [for (object in generated) object.name], sorted = names.copy();
			sorted.sort(Reflect.compare);
			if (names.join(",") != sorted.join(",")) throw "generated declarations must have deterministic order";
			if (!IrVerifier.sameType(layout.payloadType(Nullable(Enum("Paint"))), value))
				throw "null uses tag zero rather than an additional optional wrapper";
		}
		var table = IrObjectTable.of(["Holder" => objects[0], "OptionalFields" => objects[1]]);
		var lanes = new IrValueLaneLayout(table, 64, HashLink);
		if (lanes.shape(Obj("OptionalFields")).scalarWordBits != 32
			|| lanes.shape(Obj("OptionalFields"), 64).scalarWordBits != 64)
			throw "a requested shared word width must not change default struct layouts";
		for (width in [16, 128]) {
			var rejected = false;
			try lanes.shape(I32, width) catch (_:Dynamic) rejected = true;
			if (!rejected) throw "invalid word widths must fail";
		}
		var rejected = false;
		try lanes.shape(I64, 32) catch (_:Dynamic) rejected = true;
		if (!rejected) throw "a word must hold its widest scalar leaf";
		Sys.println("PASS: inline enum layout decisions agree across all targets");
	}
}
