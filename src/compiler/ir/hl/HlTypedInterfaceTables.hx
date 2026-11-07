package compiler.ir.hl;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrVerifier;
import compiler.ir.IrTypedInterfaceDispatch;
import compiler.ir.IrScalarArguments;

/** Class-owned private entries; source methods and interface views retain their semantic ABI. */
class HlTypedInterfaceTables {
	public static inline final SLOT_NATIVE = "__hl_typed_method_slot";
	public static inline final ENTRY_NATIVE = "__hl_typed_method_entry";
	public static inline final SLOT_TYPE = "haxeon_typed_method_slot";
	public static inline final ENTRY_TYPE = "haxeon_typed_method";
	public final keys:Map<String,String> = [];
	public final entries:Map<String,Array<IrObjectMethod>> = [];

	public function new(program:IrProgram) {
		var functions=[for(fn in program.functions)fn.name=>fn];
		for(fn in program.functions)if(IrTypedInterfaceDispatch.isDispatchEntry(fn.name)) {
			if(fn.arguments.length==0)throw "Typed interface dispatcher has no receiver";
			var logical=IrTypedInterfaceDispatch.originalEntryName(fn.name);
			var prefix=fn.name.substr(0,fn.name.length-logical.length),
				key="$typed-method:"+fn.name.length+":"+fn.name+":"+Std.string([for(i in 1...fn.arguments.length)fn.arguments[i].type])+":"+Std.string(fn.result),found=false;
			for(object in program.objects)if(!object.isValue) {
				var name=prefix+IrTypedInterfaceDispatch.adapterName(logical,object.name),entry=functions.get(name);
				if(entry==null)continue;
				if(!IrVerifier.sameType(entry.result,fn.result) || entry.arguments.length!=fn.arguments.length || !IrVerifier.sameType(entry.arguments[0].type,Dyn))
					throw 'Invalid private typed interface entry "$name"';
				for(i in 1...fn.arguments.length)if(!IrVerifier.sameType(entry.arguments[i].type,fn.arguments[i].type))
					throw 'Wrong private typed interface argument $i in "$name"';
				var methods=entries.get(object.name);if(methods==null)entries.set(object.name,methods=[]);
				methods.push({name:key,functionName:name});found=true;
			}
			if(found)keys.set(fn.name,key);
		}
	}
}
