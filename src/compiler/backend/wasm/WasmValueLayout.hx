package compiler.backend.wasm;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.IrObjectTable;

/** The scalar storage shape shared by Wasm GC fields and value calling conventions. */
class WasmValueLayout {
	final objects:Map<String, IrObject>;
	final layout:IrInlineValueLayout;

	public function new(program:IrProgram) {
		objects = [for (object in program.objects) object.name => object];
		layout = new IrInlineValueLayout(IrObjectTable.of(objects));
	}

	/** Optional values retain their existing reference representation at value boundaries. */
	public function isValue(type:IrType):Bool
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};

	/** Leaves are in declaration order and contain the complete path from the value root. */
	public function leaves(type:IrType):Array<IrInlineValueSlot> {
		if (!isValue(type)) throw 'Not a Wasm GC value type: $type';
		return layout.slots(type);
	}

	/** Physical field declarations preserve inherited prefixes and source declaration order. */
	public function fields(logical:Array<IrObjectField>):Array<IrObjectField> {
		var result:Array<IrObjectField> = [];
		for (field in logical) {
			if (!isValue(field.type)) result.push(field);
			else for (slot in leaves(field.type)) result.push({
				name: IrInlineValueLayout.slotName(field.name, slot),
				type: slot.type,
				nativeLayout: composedNativeLayout(field, slot),
				scalarStorage: slot.scalarStorage,
				nullableScalarStorage: slot.nullableScalarStorage
			});
		}
		return result;
	}

	/** A nested native leaf's offset is relative to every enclosing inline record. */
	function composedNativeLayout(field:IrObjectField, slot:IrInlineValueSlot):Null<compiler.ir.Ir.IrObjectFieldNativeLayout> {
		var root = switch field.type { case Obj(name): objects.get(name); default: null; };
		if (field.nativeLayout == null && (root == null || root.nativeLayout == null)) return slot.nativeLayout;
		var offset = field.nativeLayout == null ? 0 : field.nativeLayout.offset, type = field.type,
			leaf:Null<compiler.ir.Ir.IrObjectFieldNativeLayout> = null;
		for (part in slot.path) {
			var name = switch type { case Obj(value): value; default: throw 'Invalid native value path ${slot.path.join(".")}'; },
				object = objects.get(name), found:Null<IrObjectField> = null;
			if (object != null) for (candidate in object.fields) if (candidate.name == part) found = candidate;
			if (found == null || found.nativeLayout == null) throw 'Missing native layout for "$name.$part"';
			leaf = found.nativeLayout;
			offset += leaf.offset;
			type = found.type;
		}
		if (leaf == null) throw "Missing native value leaf";
		return {offset: offset, size: leaf.size, alignment: leaf.alignment, signed: leaf.signed, inlineRecord: false};
	}

	public function nativeLeaf(type:IrType, slot:IrInlineValueSlot):Null<compiler.ir.Ir.IrObjectFieldNativeLayout>
		return composedNativeLayout({name: "", type: type}, slot);

	public static function fieldName(field:String, slot:IrInlineValueSlot):String
		return IrInlineValueLayout.slotName(field, slot);
}
