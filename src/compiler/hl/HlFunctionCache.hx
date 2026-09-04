package compiler.hl;

import compiler.ir.IrFunction;

class HlFunctionCache {
	public final userSlots:Map<String, Int> = [];
	public final stableIds:Map<String, Int> = [];
	public final slots:Array<String> = [];
	public final functions:Map<String, IrFunction> = [];
	public final signatures:Map<String, String> = [];

	var nextStableId:Int = 0x10000;

	public function new(?existingStableIds:Map<String, Int>) {
		if (existingStableIds != null)
			for (name => id in existingStableIds) {
				stableIds.set(name, id);
				if (id >= nextStableId)
					nextStableId = id + 1;
			}
	}

	public function update(incoming:Array<IrFunction>):Void {
		for (fn in incoming) {
			if (!userSlots.exists(fn.name)) {
				userSlots.set(fn.name, slots.length);
				if (!stableIds.exists(fn.name))
					stableIds.set(fn.name, nextStableId++);
				slots.push(fn.name);
			}
			functions.set(fn.name, fn);
			signatures.set(fn.name, signature(fn));
		}
	}

	public function ordered():Array<IrFunction>
		return [for (name in slots) functions.get(name)];

	public static function signature(fn:IrFunction):String
		return "(" + [for (a in fn.arguments) Std.string(a.type)].join(",") + ")->" + Std.string(fn.result);
}
