import compiler.backend.wasm.WasmModule;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmTypes;
import compiler.backend.wasm.WasmTypeIdPlan;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmTypedInterfaceTables;
import compiler.backend.wasm.WasmEncoder;
import compiler.ir.Ir.IrType;
import compiler.ir.IrTypedInterfaceDispatch;

class WasmTypedInterfaceTablesMain {
 static function main():Void {
  for(gc in [false,true]) {
   var module=new WasmModule(),classes=[for(i in 0...128)'Implementation$i'],functions:Map<String,Int>=[],
    dispatch=IrTypedInterfaceDispatch.callName("Reader","read",[],I32);
   var root=module.addType({finalType:false,supertypes:[],composite:Struct([{type:Value(I32),mutable:true}])});
   var receiver:WasmValueType=gc?Ref({nullable:true,heap:Any}):I32;
   var signature:WasmFunctionType={parameters:[receiver],results:[I32]};
   functions.set(dispatch,module.addFunction(new WasmFunction(dispatch,signature,[],[I32Const(-100),Return])));
   for(name in classes) {
    var entry=IrTypedInterfaceDispatch.adapterName(dispatch,name);
    // Distinct reference-type records must canonicalize to the same ABI.
    var parameter:WasmValueType=gc?Ref({nullable:true,heap:Any}):I32;
    functions.set(entry,module.addFunction(new WasmFunction(entry,{parameters:[parameter],results:[I32]},[],[I32Const(42),Return])));
   }
   var invalid=IrTypedInterfaceDispatch.adapterName(dispatch,"InvalidSignature");
   functions.set(invalid,module.addFunction(new WasmFunction(invalid,{parameters:[receiver],results:[I64]},[],[I64Const(0),Return])));
   module.runtimeTypeIds=new WasmTypeIdPlan([for(name in classes.concat(["InvalidSignature"]))Obj(name)]);
   var slots=WasmModuleSupport.buildTableSlots(module,functions);
   WasmTypedInterfaceTables.lower(module,functions,slots,gc?root:null);
   var query:Null<WasmFunction>=null;
   for(fn in module.functions)if(StringTools.startsWith(fn.name,"$typed-interface-table:"))query=fn;
   if(query==null)throw "No static class table was generated";
   var standalone=new WasmModule();standalone.addFunction(query);standalone.exports.push({name:"lookup",functionIndex:0});
   var path='out/typed-method-table-${gc?"gc":"linear"}.wasm';sys.io.File.saveBytes(path,WasmEncoder.encode(standalone));
   var expected=[for(name in classes){id:module.runtimeTypeId(Obj(name)),slot:slots.get(IrTypedInterfaceDispatch.adapterName(dispatch,name))}];
   var cases=haxe.Json.stringify(expected),missing=module.runtimeTypeId(Obj("InvalidSignature"));
   var js='const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1])),{}).exports;const cases=$cases;for(const x of cases)if(e.lookup(x.id)!==x.slot)throw Error("Wrong slot "+x.id);if(e.lookup($missing)!==-1)throw Error("Wrong ABI accepted");const ids=new Set(cases.map(x=>x.id));for(let i=0;i<10000;i++)if(!ids.has(i)&&e.lookup(i)!==-1)throw Error("Unknown class accepted "+i);';
   var status=Sys.command("node",["-e",js,path]);sys.FileSystem.deleteFile(path);
   if(status!=0)throw "Static typed class table failed";
  }
  Sys.println("PASS: typed class tables check complete IDs and canonical signatures for scalar and GC reference receivers");
 }
}
