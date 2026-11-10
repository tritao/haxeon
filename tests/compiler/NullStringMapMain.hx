import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;

class NullStringMapMain {
 static function main():Void {
  var source=sys.io.File.getContent("tests/programs/map-null-string-keys.hx");
  if(new compiler.ir.IrInterpreter(compiler.Frontend.compile(source)).run("main")!=42) throw "Interpreter String map null-key semantics differ";
  Sys.println("PASS: String map null keys interpreter");
  var exports=["NullStringMapCensus.prepare","NullStringMapCensus.perform"];
  for(target in ["hl","wasm32","wasm-gc"]) for(inlining in [false,true]) {
   var c=new Compiler(null,compiler.runtime.CompilerIntrinsics.configuration()); c.addStandardLibrarySourceRoot("stdlib"); c.setExportedFunctions(exports);
   c.configure("null-map-"+target+inlining,"null-map",CompilerDriver.targetDefines(target).concat(["haxeon-inline="+(inlining?1:0)]));
   var input=source;
   if(target=="hl") input+='function census():Int { NullStringMapCensus.prepare(); var before=hl.Gc.totalAllocated(); var small=NullStringMapCensus.perform(8); if(small!=8 || hl.Gc.totalAllocated()!=before) return 1; before=hl.Gc.totalAllocated(); var result=NullStringMapCensus.perform(1024); return result==1024 && hl.Gc.totalAllocated()==before ? 42 : 1; }';
   c.update("Main.hx",input); var result=c.compile("Main"),temp=Sys.getEnv("TMPDIR"); if(temp==null)temp="out";
   var path=temp+"/null-map-"+target+inlining+(target=="hl"?".hl":".wasm");
   sys.io.File.saveBytes(path,target=="hl"?HlWriter.encode(result.module).flatten():new WasmBackend().compile(result.ir,{
    target:target=="wasm32"?Wasm32:WasmGc,debugNames:true,wasmMemoryStats:target=="wasm32",wasmGcAllocationCount:target=="wasm-gc",exports:exports
   }).bytes);
   if(target=="hl") {
    var status=Sys.command("scripts/hl",[path]);if(status!=42)throw "HL null map returned "+status;
    var live=runtime.Runtime.load(sys.io.File.getBytes(path),result.runtimeIdentity);
    if(runtime.Runtime.callInt(live,result.functionIds.get("Main.census"))!=42)throw "HL null map query allocated";
    runtime.Runtime.dispose(live);
   } else {
    var js='const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;const result=e.main();if(result!==42)throw Error("result "+result);const c=e.__allocation_count||e["haxeon.memory.allocation_count"];e["NullStringMapCensus.prepare"]();for(const n of [8,1024]){const before=c();if(e["NullStringMapCensus.perform"](n)!==n||c()!==before)throw Error("null query allocated");}';
    if(Sys.command("node",["-e",js,path])!=0)throw target+" null map failed";
   }
   sys.FileSystem.deleteFile(path);Sys.println("PASS: String map null keys "+target+" inline="+inlining);
  }
 }
}
