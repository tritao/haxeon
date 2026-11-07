import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;

/** Generated closure conversions reuse interface helpers already assembled by earlier passes. */
class ValueInterfaceHelperReuseMain {
 static function main() {
  for(target in ["hl", "wasm32", "wasm-gc"]) for(inlining in [false, true]) {
   var c=new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
   c.addSourceRoot("stdlib");
   c.configure("interface-reuse-"+target+inlining,"interface-reuse",CompilerDriver.targetDefines(target).concat(["haxeon-inline="+(inlining?1:0)]));
   c.update("Main.hx",sys.io.File.getContent("tests/programs/value-interface-helper-reuse.hx"));
   var result=c.compile("Main"),temp=Sys.getEnv("TMPDIR");if(temp==null)temp="out";
   var path=temp+"/interface-reuse-"+target+inlining+(target=="hl"?".hl":".wasm");
   sys.io.File.saveBytes(path,target=="hl"?HlWriter.encode(result.module):new WasmBackend().compile(result.ir,{target:target=="wasm32"?Wasm32:WasmGc,debugNames:true}).bytes);
   var status=Sys.command(target=="hl"?"scripts/hl":"node",target=="hl"?[path]:["-e",'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;if(e.main()!==42)throw Error("interface callback result");',path]);
   if(status!=(target=="hl"?42:0))throw "Failed "+target+" inline="+inlining+": "+status;
   sys.FileSystem.deleteFile(path);Sys.println("PASS "+target+" inline="+inlining);
  }
 }
}
