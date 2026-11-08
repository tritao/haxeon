package compiler.backend.wasm;

import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmTypes;
import compiler.ir.Ir;
import compiler.ir.IrTypedInterfaceDispatch;

private typedef Entry = {final id:Int; final slot:Int;}

/** Static class entries indexed by existing class IDs, with at most two table branches per lookup. */
class WasmTypedInterfaceTables {
	static function base(name:String):String {
		while(true) {
			if(StringTools.startsWith(name,"$wasm:scalar-function:")) {
				var rest=name.substr("$wasm:scalar-function:".length), colon=rest.indexOf(":");
				if(colon<0)throw "Malformed scalar function name";
				name=rest.substr(colon+1);
			} else {
				var original=IrTypedInterfaceDispatch.originalEntryName(name);
				if(original==name)return name;
				name=original;
			}
		}
	}
	static function adapter(name:String):Null<{dispatch:String,object:String}> {
		var plain=base(name);
		if(!StringTools.startsWith(plain,IrTypedInterfaceDispatch.ADAPTER_PREFIX))return null;
		var rest=plain.substr(IrTypedInterfaceDispatch.ADAPTER_PREFIX.length),colon=rest.indexOf(":"),length=Std.parseInt(rest.substr(0,colon));
		if(length==null || colon<0)throw "Malformed typed interface entry";
		var dispatch=rest.substr(colon+1,length),tail=rest.substr(colon+length+2),separator=tail.indexOf(":"),objectLength=Std.parseInt(tail.substr(0,separator)),object=tail.substr(separator+1);
		if(separator<0 || objectLength==null || object.length!=objectLength)throw "Malformed typed interface class entry";
		return {dispatch:dispatch,object:object};
	}
	static function hash(id:Int,seed:Int,bits:Int):Int return bits==0?0:(id*seed) >>> (32-bits);
	static function bits(size:Int):Int {var n=0;while((1<<n)<size)n++;return n;}
	static function seed(attempt:Int):Int return (attempt*0x9e3779b9)|1;

	static function lookup(name:String,entries:Array<Entry>):WasmFunction {
		var firstBits=bits(entries.length),firstSize=1<<firstBits,firstSeed=1,buckets:Array<Array<Entry>>=[];
		var attempt=0;
		while(true) {
			firstSeed=seed(++attempt);buckets=[for(_ in 0...firstSize)[]];
			for(entry in entries)buckets[hash(entry.id,firstSeed,firstBits)].push(entry);
			var total=0;for(bucket in buckets)total+=bucket.length*bucket.length;
			if(total<=4*entries.length)break;
			if(attempt>10000)throw "Cannot construct primary typed method table";
		}
		var body:Array<WasmInstruction>=[];
		// A block per bucket: br_table selects its code directly, without testing preceding buckets.
		body.push(Block(null));for(_ in buckets)body.push(Block(null));
		body=body.concat([LocalGet(0),I32Const(firstSeed),I32Mul]);
		if(firstBits==0)body=body.concat([Drop,I32Const(0)]);else body=body.concat([I32Const(32-firstBits),I32ShrU]);
		body.push(BrTable([for(i in 0...firstSize)i],firstSize));
		for(bucket in buckets) {
			body.push(End);
			if(bucket.length==0)body=body.concat([I32Const(-1),Return]);
			else if(bucket.length==1)body=body.concat(checkedEntry(bucket[0]));
			else {
				var secondBits=bits(bucket.length*bucket.length),size=1<<secondBits,slots:Array<Null<Entry>>=[],secondSeed=1,trial=0;
				while(true) {
					secondSeed=seed(++trial);slots=[for(_ in 0...size)null];var collision=false;
					for(entry in bucket){var index=hash(entry.id,secondSeed,secondBits);if(slots[index]!=null){collision=true;break;}slots[index]=entry;}
					if(!collision)break;
					if(trial>100000)throw "Cannot construct secondary typed method table";
				}
				body.push(Block(null));for(_ in slots)body.push(Block(null));
				body=body.concat([LocalGet(0),I32Const(secondSeed),I32Mul,I32Const(32-secondBits),I32ShrU,BrTable([for(i in 0...size)i],size)]);
				for(entry in slots){body.push(End);body=body.concat(entry==null?[I32Const(-1),Return]:checkedEntry(entry));}
				body=body.concat([End,I32Const(-1),Return]);
			}
		}
		body=body.concat([End,I32Const(-1),Return]);
		return new WasmFunction(name,{parameters:[I32],results:[I32]},[],body);
	}
	static function checkedEntry(entry:Entry):Array<WasmInstruction>
		return [LocalGet(0),I32Const(entry.id),I32Eq,If(I32),I32Const(entry.slot),Else,I32Const(-1),End,Return];

	public static function lower(module:WasmModule,functions:Map<String,Int>,tableSlots:Map<String,Int>,?gcRoot:Int):Void {
		var names=[for(name in functions.keys())if(StringTools.startsWith(base(name),IrTypedInterfaceDispatch.PREFIX))name];names.sort(Reflect.compare);
		for(name in names) {
			var index=functions.get(name);if(index==null)throw "Missing typed dispatcher";
			var original=module.functionAt(index),entries:Array<Entry>=[],seen:Map<String,Bool>=[],targetNames=[for(n in tableSlots.keys())n];targetNames.sort(Reflect.compare);
			for(target in targetNames) {
				var entry=adapter(target);if(entry==null || entry.dispatch!=base(name) || seen.exists(entry.object))continue;
				var targetIndex=functions.get(target);if(targetIndex==null)throw "Missing typed class entry";
				if(module.typeIndex(original.type)!=module.typeIndex(module.functionType(targetIndex)))continue;
				var targetSlot=tableSlots.get(target);if(targetSlot==null)throw "Missing typed method table slot";
				seen.set(entry.object,true);entries.push({id:module.runtimeTypeId(Obj(entry.object)),slot:targetSlot});
			}
			if(entries.length==0)continue;
			var query=entries.length==1?-1:module.addFunction(lookup("$typed-interface-table:"+name,entries)),fallback=module.addFunction(new WasmFunction("$typed-interface-fallback:"+name,original.type,original.locals,original.body)),slot=original.type.parameters.length;
			var body:Array<WasmInstruction>=[];
			// Preserve the verified throwing path for a null or non-class receiver.
			if(gcRoot==null)body=body.concat([LocalGet(0),I32Eqz,If(null)]);
			else body=body.concat([LocalGet(0),RefTest({nullable:false,heap:Type(gcRoot)}),I32Eqz,If(null)]);
			body=body.concat(forward(original.type)).concat([Call(fallback),Return,End,LocalGet(0)]);
			if(gcRoot==null)body.push(I32Load(0));else body=body.concat([RefCast({nullable:false,heap:Type(gcRoot)}),StructGet(gcRoot,0)]);
			// A closed contract with one entry can call it directly after checking the full class ID.
			if(entries.length==1) {
				body=body.concat([I32Const(entries[0].id),I32Eq,If(null)]).concat(forward(original.type))
					.concat([Call(module.tableElements[entries[0].slot]),Return,End]).concat(forward(original.type)).concat([Call(fallback),Return]);
			} else {
				body=body.concat([Call(query),LocalTee(slot),I32Const(-1),I32Eq,If(null)]).concat(forward(original.type)).concat([Call(fallback),Return,End]);
				body=body.concat(forward(original.type)).concat([LocalGet(slot),CallIndirect(module.typeIndex(original.type)),Return]);
			}
			module.setFunction(index,new WasmFunction(name,original.type,[{type:I32}],body));
		}
	}
	static function forward(type:WasmFunctionType):Array<WasmInstruction> return [for(i in 0...type.parameters.length)LocalGet(i)];
}
