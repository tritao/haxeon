import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrValueLaneReference;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
/** Internal packet storage only: public source enum array descriptors are not activated. */
@:access(compiler.ir.IrBuilder)
class InlineEnumCarrierArrayMain {
 static function tempRoot():String { var root=Sys.getEnv("TMPDIR");return root==null?"/tmp":root; }
 static final uniqueStem="InlineEnumCarrierArrayMain-"+Std.random(0x7fffffff)+"-";
 static function global(b:IrBuilder,name:String,type:IrType):IrValue { var value=b.temporary(type);b.emit(GlobalGet(value,name));return value; }
 static function main():Void {
  for (inlineEnabled in [false,true]) for(target in [HashLink,Wasm32,WasmGc])check(target,inlineEnabled);
 }
 static function check(target:IrValueLaneTarget,inlineEnabled:Bool):Void {
  var owner:IrObject={name:"Owner",isValue:false,base:null,interfaces:[],methods:[],fields:[]};
  var packet:IrObject={name:"Packet",isValue:true,base:null,interfaces:[],methods:[],fields:[{name:"tag",type:I32},{name:"optional",type:Nullable(I32)},{name:"reference0",type:IrValueLaneReference.type()}]};
  var table=compiler.ir.IrObjectTable.of([owner.name=>owner,packet.name=>packet]),type:IrType=Obj(packet.name),arrayType:IrType=Array(type);
  var factory=new compiler.ir.IrValueArrayFactory(table,type,target==HashLink?64:32,target,0),helpers=factory.helpers;
  var prepare=new IrBuilder(),reference=prepare.newObject("Owner"),shape=factory.layout.lanes;
  var array=prepare.call(factory.natives()[0].name,[prepare.constInt(1),prepare.typeValue(type),prepare.constInt(shape.scalarStrideBits),prepare.constInt(shape.references),prepare.constInt(shape.scalarWordBits),prepare.constBool(factory.layout.hasValidity)],arrayType);
  prepare.emit(GlobalSet("array",array));prepare.emit(GlobalSet("owner",reference));prepare.returnValue(prepare.constVoid());
  var b=new IrBuilder(),array=global(b,"array",arrayType),reference=global(b,"owner",Obj("Owner")),index=b.constInt(0),carrier=b.call(IrValueLaneReference.PACK,[reference],IrValueLaneReference.type());
  b.call(helpers.setter(helpers.slot(["tag"])),[array,index,b.constInt(7)],Void);
  b.call(helpers.setter(helpers.slot(["reference0"])),[array,index,carrier],Void);
  b.call("__value_array_mark",[array,index],Void);
  var loaded=b.call(helpers.getter(helpers.slot(["reference0"])),[array,index],IrValueLaneReference.type());
  var restored=b.call(IrValueLaneReference.UNPACK,[loaded],Obj("Owner")),yes=b.createBlock(),no=b.createBlock();
  b.branch(b.equal(restored,reference),yes,no);b.select(yes);b.returnValue(b.constInt(42));b.select(no);b.returnValue(b.constInt(1));
  var p=new IrProgram("main");p.objects=[owner,packet];
  p.staticFields=[{name:"array",type:arrayType},{name:"owner",type:Obj("Owner")}];
  p.functions=[new IrFunction("prepare",prepare.arguments,Void,prepare.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose),new IrFunction("main",b.arguments,I32,b.blocks, Ordinary)].concat(helpers.functions());
  p.natives=factory.natives().concat(helpers.natives());
  compiler.ir.IrInliner.run(p,new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm,inlineEnabled);
  compiler.ir.IrVerifier.verify(p);
  var entry=new IrBuilder(),captures:Array<{path:String,count:Int}>=[];
  entry.call("prepare",[],Void);var result=entry.call("main",[],I32);
  if(target==HashLink) {
   p.natives=p.natives.concat([{name:"start",library:"std",symbol:"gc_census_start",arguments:[I32],result:Void},{name:"stop",library:"std",symbol:"gc_census_stop",arguments:[],result:Void},{name:"reset",library:"std",symbol:"gc_census_reset",arguments:[],result:Void},{name:"dump",library:"haxeon_runtime",symbol:"__gc_census_dump",arguments:[Bytes],result:Void}]);
   for(n in [8,1024]) {
    var path=tempRoot()+"/"+uniqueStem+"carrier-array-"+n+".json";captures.push({path:path,count:n});
    entry.call("reset",[],Void);entry.call("start",[entry.constInt(0)],Void);for(_ in 0...n)entry.call("main",[],I32);entry.call("stop",[],Void);entry.call("dump",[entry.constString(path)],Void);
   }
  }
  p.natives.push({name:"__exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void});entry.call("__exit",[result],Void);entry.returnValue(entry.constVoid());
  p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks, Ordinary));p.entryPoint=target==HashLink?"entry":"main";
  var targetBackend:compiler.backend.Backend.BackendTarget=target==HashLink?HashLink:target==Wasm32?Wasm32:WasmGc;
  var bytes=target==HashLink?new compiler.backend.hl.HlBackend().compile(p,{target:targetBackend,debugNames:true}).bytes:new compiler.backend.wasm.WasmBackend().compile(p,{target:targetBackend,debugNames:true,wasmGcAllocationCount:target==WasmGc,wasmMemoryStats:target==Wasm32}).bytes;
  var path=tempRoot()+"/"+uniqueStem+"carrier-array-"+Std.string(target)+(target==HashLink?".hl":".wasm");sys.io.File.saveBytes(path,bytes);
  var js='const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports,c=e.__allocation_count||e["haxeon.memory.allocation_count"];e.prepare();e.main();for(const n of [8,1024]){const before=c();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("result");if(c()!==before)throw Error("carrier array boxing: "+(c()-before));}';
  var child=new sys.io.Process(target==HashLink?"scripts/hl":"node",target==HashLink?[path]:["-e",js,path]);var output=child.stdout.readAll().toString(),error=child.stderr.readAll().toString(),code=child.exitCode();child.close();sys.FileSystem.deleteFile(path);
  if(code!=(target==HashLink?42:0))throw Std.string(target)+": "+code+" "+output+" "+error;
  for(capture in captures){var census:Dynamic=haxe.Json.parse(sys.io.File.getContent(capture.path));sys.FileSystem.deleteFile(capture.path);if(census.allocations!=0)throw "Carrier array allocation: "+census.allocations;}
  Sys.println("PASS: "+Std.string(target)+" carrier array leaves; zero allocations at 8/1024 calls");
 }
}
