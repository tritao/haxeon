import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrScalarWordBits;
import compiler.ir.IrInlineEnumWordAccess;
import compiler.ir.IrValueLaneLayout.IrValueLaneSlot;
import compiler.backend.Backend.BackendTarget;

/** Physical pointer/type-ID words are never managed-reference casts or Dynamic boxes. */
@:access(compiler.ir.IrBuilder)
class InlineEnumPointerWordMain {
 static function tempRoot():String { var root=Sys.getEnv("TMPDIR");return root==null?"/tmp":root; }
 static final uniqueStem="InlineEnumPointerWordMain-"+Std.random(0x7fffffff)+"-";
 static function main():Void {
  for(target in [HashLink,Wasm32,WasmGc])for(bits in (target==HashLink?[64]:[32,64]))check(target,bits);
 }
 static function check(target:BackendTarget,bits:Int):Void {
  var b=new IrBuilder(),word:IrType=bits==64?I64:I32,payload=b.newObject("Words"),words=new IrInlineEnumWordAccess(bits);
  for(i in 0...4)b.fieldSet(payload,"scalar"+i,b.constInt(0,word));
  var raw=b.call(IrScalarWordBits.UNPACK,[b.add(b.shiftLeft(b.constInt(1,I64),b.constInt(50)),b.constInt(0x12345678,I64))],RawPtr);
  var type=b.typeValue(Obj("Owner")),width=target==HashLink?64:32;
  var pointerSlot:IrValueLaneSlot={path:[],type:RawPtr,isPresence:false,nullablePayload:false,index:0,isReference:false,bitOffset:bits-8,bitWidth:width,signed:false};
  var typeSlot:IrValueLaneSlot={path:[],type:TypeRef,isPresence:false,nullablePayload:false,index:2,isReference:false,bitOffset:bits-8,bitWidth:width,signed:false};
  words.write(b,payload,pointerSlot,raw);words.write(b,payload,typeSlot,type);
  var checks=[b.equal(b.call(IrScalarWordBits.PACK,[words.read(b,payload,pointerSlot)],I64),b.call(IrScalarWordBits.PACK,[raw],I64)),b.equal(b.call(IrScalarWordBits.PACK,[words.read(b,payload,typeSlot)],I64),b.call(IrScalarWordBits.PACK,[type],I64))];
  if(target!=HashLink) {
   var callbackType:IrType=Abstract("native_callback"),callback=b.call(IrScalarWordBits.UNPACK,[b.constInt(-2023406815,I64)],callbackType);
   var callbackSlot:IrValueLaneSlot={path:[],type:callbackType,isPresence:false,nullablePayload:false,index:2,isReference:false,bitOffset:bits-8,bitWidth:32,signed:false};
   words.write(b,payload,callbackSlot,callback);
   checks.push(b.equal(b.call(IrScalarWordBits.PACK,[words.read(b,payload,callbackSlot)],I64),b.call(IrScalarWordBits.PACK,[callback],I64)));
  }
  var bad=b.createBlock();for(value in checks){var next=b.createBlock();b.branch(value,next,bad);b.select(next);}b.returnValue(b.constInt(42));b.select(bad);b.returnValue(b.constInt(1));
  var p=new IrProgram("main");p.objects=[{name:"Owner",isValue:false,base:null,interfaces:[],methods:[],fields:[]},{name:"Words",isValue:true,base:null,interfaces:[],methods:[],fields:[for(i in 0...4){name:"scalar"+i,type:word}]}];
  p.functions=[new IrFunction("main",b.arguments,I32,b.blocks, None)];p.natives=IrInlineEnumWordAccess.natives();
  var table=compiler.ir.IrObjectTable.of([for(o in p.objects)o.name=>o]);p.functions=[for(fn in p.functions)compiler.ir.IrScalarReplacement.rewrite(fn,table,false)];
  var entry=new IrBuilder(),warm=entry.call("main",[],I32),captures:Array<String>=[];
  if(target==HashLink) {
   p.natives=p.natives.concat([{name:"start",library:"std",symbol:"gc_census_start",arguments:[I32],result:Void},{name:"stop",library:"std",symbol:"gc_census_stop",arguments:[],result:Void},{name:"reset",library:"std",symbol:"gc_census_reset",arguments:[],result:Void},{name:"dump",library:"haxeon_runtime",symbol:"__gc_census_dump",arguments:[Bytes],result:Void}]);
   for(n in [8,1024]){var path=tempRoot()+"/"+uniqueStem+"pointer-words-"+n+".json";captures.push(path);entry.call("reset",[],Void);entry.call("start",[entry.constInt(0)],Void);for(_ in 0...n)entry.call("main",[],I32);entry.call("stop",[],Void);entry.call("dump",[entry.constString(path)],Void);}
  }
  p.natives.push({name:"__exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void});entry.call("__exit",[warm],Void);entry.returnValue(entry.constVoid());p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks, None));p.entryPoint=target==HashLink?"entry":"main";
  compiler.ir.IrVerifier.verify(p);
  var bytes=target==HashLink?new compiler.backend.hl.HlBackend().compile(p,{target:target,debugNames:true}).bytes:new compiler.backend.wasm.WasmBackend().compile(p,{target:target,debugNames:true,wasmGcAllocationCount:target==WasmGc,wasmMemoryStats:target==Wasm32}).bytes;
  var path=tempRoot()+"/"+uniqueStem+"pointer-words-"+Std.string(target)+(target==HashLink?".hl":".wasm");sys.io.File.saveBytes(path,bytes);
  var js='const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports,c=e.__allocation_count||e["haxeon.memory.allocation_count"];e.main();for(const n of [8,1024]){const before=c();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("pointer/type bits");if(c()!==before)throw Error("pointer/type boxing");}';
  var child=new sys.io.Process(target==HashLink?"scripts/hl":"node",target==HashLink?[path]:["-e",js,path]);var output=child.stdout.readAll().toString(),error=child.stderr.readAll().toString(),code=child.exitCode();child.close();sys.FileSystem.deleteFile(path);if(code!=(target==HashLink?42:0))throw Std.string(target)+" words="+bits+": "+code+" "+output+" "+error;
  for(capture in captures){var census:Dynamic=haxe.Json.parse(sys.io.File.getContent(capture));sys.FileSystem.deleteFile(capture);if(census.allocations!=0)throw "Pointer/type boxes: "+census.allocations;}
  Sys.println("PASS: "+Std.string(target)+" words="+bits+" pointer/type crossings; zero allocations at8/1024 calls");
 }
}
