package compiler.ir;

import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectFieldNativeLayout;
import compiler.ir.Ir.IrScalarStorage;
import compiler.ir.Ir.IrType;

/** One storage slot in a recursively flattened value. */
typedef IrInlineValueSlot = {
	/** Source field names from the value root; an optional's flag uses the optional's path. */
	final path:Array<String>;
	final type:IrType;
	final isPresence:Bool;
	/** Native scalar storage metadata, if this leaf belongs to a native-layout value. */
	final nativeLayout:Null<IrObjectFieldNativeLayout>;
	/** Stored scalar width, including fields of values that contain managed references. */
	@:optional final scalarStorage:Null<IrScalarStorage>;
	/** Stored width of a nullable primitive's payload. */
	@:optional final nullableScalarStorage:Null<IrScalarStorage>;
}

/**
 * Backend-independent shape of an inline value. References, arrays and ordinary objects stay single slots; nested value
 * objects expand recursively. Optional values contribute a presence slot followed by their payload slots. Keeping the
 * source path separate from the generated physical name lets field-place lowering preserve aliases and diagnostics.
 */
class IrInlineValueLayout {
	final objects:IrObjectTable;

	public function new(objects:IrObjectTable)
		this.objects = objects;

	public function slots(type:IrType):Array<IrInlineValueSlot> {
		var result:Array<IrInlineValueSlot> = [];
		append(type, [], [], null, null, null, result);
		return result;
	}

	function append(type:IrType, path:Array<String>, visiting:Array<String>, nativeLayout:Null<IrObjectFieldNativeLayout>, scalarStorage:Null<IrScalarStorage>,
			nullableScalarStorage:Null<IrScalarStorage>,
			result:Array<IrInlineValueSlot>):Void {
		switch type {
			case Nullable(Obj(name)) if (isValue(name)):
				result.push({path: path.copy(), type: Bool, isPresence: true, nativeLayout: null});
				append(Obj(name), path, visiting, null, null, null, result);
			case Obj(name) if (isValue(name)):
				if (visiting.indexOf(name) >= 0)
					throw 'Value layout contains a by-value cycle at "$name"';
				var object = objects.get(name), next = visiting.concat([name]);
				if (object == null)
					throw 'Missing value object "$name"';
				for (field in object.fields)
					append(field.type, path.concat([field.name]), next, field.nativeLayout, IrFieldStorage.scalar(field), field.nullableScalarStorage, result);
			default:
				result.push({path: path.copy(), type: type, isPresence: false, nativeLayout: nativeLayout, scalarStorage: scalarStorage,
					nullableScalarStorage: nullableScalarStorage});
		}
	}

	function isValue(name:String):Bool {
		var object = objects.get(name);
		return object != null && object.isValue;
	}

	/** A collision-free internal identifier, independent of source field spelling. */
	public static function slotName(prefix:String, slot:IrInlineValueSlot):String {
		var result = '$' + 'inline:' + prefix.length + ':' + prefix;
		for (part in slot.path)
			result += ':' + part.length + ':' + part;
		return result + (slot.isPresence ? ':present' : ':value');
	}
}
