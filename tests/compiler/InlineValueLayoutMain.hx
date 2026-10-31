import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrObjectTable;
import compiler.ir.IrOptionalFieldStorage;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;

/** Inline nullable payloads retain every reference and nested presence flag in their holder's layout. */
class InlineValueLayoutMain {
	static function main():Void {
		var objects:Map<String, IrObject> = [];
		objects.set("Child", {
			name: "Child", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "x", type: I32}, {name: "label", type: Bytes}]
		});
		objects.set("Value", {
			name: "Value", isValue: true, base: null, interfaces: [], methods: [],
			fields: [{name: "child", type: Nullable(Obj("Child"))}, {name: "owner", type: Obj("Owner")}]
		});
		objects.set("Owner", {
			name: "Owner", isValue: false, base: null, interfaces: [], methods: [], fields: [{name: "value", type: Obj("Value")}]
		});
		var slots = new IrInlineValueLayout(IrObjectTable.of(objects)).slots(Nullable(Obj("Value")));
		var expected = [":present:Bool", "child:present:Bool", "child.x:value:I32", "child.label:value:Bytes", "owner:value:Obj(Owner)"];
		var actual = [for (slot in slots) slot.path.join(".") + (slot.isPresence ? ":present:" : ":value:") + Std.string(slot.type)];
		if (actual.join(",") != expected.join(","))
			throw 'Wrong inline value slots: ${actual.join(",")}';
		var names:Map<String, Bool> = [];
		for (slot in slots) {
			var name = IrInlineValueLayout.slotName("field", slot);
			if (names.exists(name)) throw 'Duplicate inline slot "$name"';
			names.set(name, true);
		}
		var lowering = new IrOptionalFieldStorage([for (object in objects) object]);
		if (!lowering.hasFields()) throw "missing nullable field storage plan";
		var physical = lowering.physicalObjects([objects.get("Value")])[0];
		if (physical.fields.length != 4) throw 'wrong nullable field storage: ${physical.fields.length}';
		var builder = new IrBuilder(), holder = builder.newObject("Value"), child = builder.newObject("Child");
		builder.fieldSet(child, "x", builder.constInt(42));
		builder.fieldSet(child, "label", builder.constString("kept"));
		builder.fieldSet(holder, "child", builder.toDyn(child, Nullable(Obj("Child"))));
		var read = builder.safeCast(builder.fieldGet(holder, "child", Nullable(Obj("Child"))), Obj("Child"));
		var x = builder.fieldGet(read, "x", I32);
		builder.fieldSet(holder, "child", builder.constNull(Nullable(Obj("Child"))));
		var after = builder.fieldGet(holder, "child", Nullable(Obj("Child"))), yes = builder.createBlock(), no = builder.createBlock();
		builder.branch(builder.equal(after, builder.constNull(Nullable(Obj("Child")))), yes, no);
		builder.select(yes);
		var childSlots = new IrInlineValueLayout(IrObjectTable.of(objects)).slots(Nullable(Obj("Child")));
		var payloadX = builder.fieldGet(holder, IrInlineValueLayout.slotName("child", childSlots[1]), I32);
		var cleared = builder.createBlock();
		builder.branch(builder.equal(payloadX, builder.constInt(0)), cleared, no);
		builder.select(cleared);
		var payloadLabel = builder.fieldGet(holder, IrInlineValueLayout.slotName("child", childSlots[2]), Bytes);
		var success = builder.createBlock();
		builder.branch(builder.equal(payloadLabel, builder.constNull(Bytes)), success, no);
		builder.select(success);
		builder.returnValue(x);
		builder.select(no);
		builder.returnValue(builder.constInt(0));
		var program = new IrProgram("main");
		program.objects = lowering.physicalObjects([for (object in objects) object]);
		program.functions = lowering.rewrite([new IrFunction("main", [], I32, builder.blocks)]);
		IrVerifier.verify(program);
		if (new IrInterpreter(program).run() != 42) throw "nullable inline field did not retain and clear its value";
		Sys.println("PASS: inline value layout preserves nested presence and reference slots");
	}
}
