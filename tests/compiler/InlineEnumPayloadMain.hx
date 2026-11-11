import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrInlineEnumCaseAccess;
import compiler.ir.IrObjectTable;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
class InlineEnumPayloadMain {
 static function tempRoot():String { var root=Sys.getEnv("TMPDIR");return root==null?"/tmp":root; }
 static final uniqueStem="InlineEnumPayloadMain-"+Std.random(0x7fffffff)+"-";
 static function main() {
  for(inlineEnabled in [false,true])for(target in [HashLink,Wasm32,WasmGc])check(target,inlineEnabled);
  Sys.println("PASS: direct inline enum case construction/projection on all targets, with and without inlining");
 }
 static function check(target:IrValueLaneTarget,inlineEnabled:Bool) {
  var source:IrObject={name:"Source",isValue:false,base:null,interfaces:[],methods:[],fields:[]};
  var small:IrObject={name:"Small",isValue:true,base:null,interfaces:[],methods:[],fields:[{name:"tiny",type:I32,scalarStorage:{size:1,signed:true}},{name:"owner",type:Obj("Source")}]};
  var declarations:Array<IrEnum>=[{name:"Mixed",cases:[{name:"Empty",params:[]},{name:"Payload",params:[I32,Obj("Small"),Nullable(I32),Nullable(Obj("Small")),F32]},{name:"Wide",params:[F64,RawPtr,TypeRef,Abstract("native_callback")]}]},
   {name:"Outer",cases:[{name:"Wrapped",params:[Enum("Mixed")]}]}];
  var planner=new IrInlineEnumLayout(declarations,[source,small],target==HashLink?64:32,target);
  var mixed=planner.shape("Mixed"),outer=planner.shape("Outer");if(mixed==null||outer==null)throw "Expected inline shape";
  var objects=[source,small].concat(planner.generatedObjects()),table=IrObjectTable.of([for(o in objects)o.name=>o]);
  var access=new IrInlineEnumCaseAccess(mixed,table),outside=new IrInlineEnumCaseAccess(outer,table);
  var b=new IrBuilder(),owner=b.newObject("Source"),record=b.newObject("Small");
  b.fieldSet(record,"tiny",b.constInt(-2));b.fieldSet(record,"owner",owner);
  var f32=b.constFloat(-0.125,F32),raw=b.call(compiler.ir.IrScalarWordBits.UNPACK,[b.constInt(0x12345678,I64)],RawPtr),type=b.typeValue(Obj("Source")),callback=b.constNull(Abstract("native_callback"));
  var optional=b.toDyn(b.constInt(-7),Nullable(I32)),none=b.constNull(Nullable(Obj("Small")));
  var value=access.construct(b,1,[b.constInt(1234),record,optional,none,f32]);
  var relayed=b.call(compiler.ir.IrInlineEnumCaseAccess.HELPER_PREFIX+"forward",[value],Obj(mixed.valueObject.name));
  var wrapped=outside.construct(b,0,[relayed]),restored=outside.field(b,wrapped,0,0);
  var restoredRecord=access.field(b,restored,1,1),restoredOptional=access.field(b,restored,1,2),restoredNone=access.field(b,restored,1,3);
  var empty=access.construct(b,0,[]),nil=access.nullValue(b);
  var checks=[b.equal(access.field(b,restored,1,0),b.constInt(1234)),
   b.equal(b.fieldGet(restoredRecord,"tiny",I32),b.constInt(-2)),
   b.equal(b.fieldGet(restoredRecord,"owner",Obj("Source")),owner),
   b.equal(b.safeCast(restoredOptional,I32),b.constInt(-7)),
   b.equal(restoredNone,b.constNull(Nullable(Obj("Small")))),
   b.equal(b.fieldGet(empty,"tag",I32),b.constInt(1)),b.equal(b.fieldGet(nil,"tag",I32),b.constInt(0))];
  checks.push(b.equal(b.call("__f32_to_i32_bits",[access.field(b,restored,1,4)],I32),b.call("__f32_to_i32_bits",[f32],I32)));
  var someRecord=b.toDyn(record,Nullable(Obj("Small")));
  var other=access.construct(b,1,[b.constInt(4321),record,b.constNull(Nullable(I32)),someRecord,f32]);
  var otherRecord=b.safeCast(access.field(b,other,1,3),Obj("Small"));
  checks.push(b.equal(b.fieldGet(otherRecord,"tiny",I32),b.constInt(-2)));
  checks.push(b.equal(b.fieldGet(otherRecord,"owner",Obj("Source")),owner));
  checks.push(b.equal(access.field(b,other,1,2),b.constNull(Nullable(I32))));
  for(number in [-12.5,-0.0,Math.NaN]) {
   var floating=b.constFloat(number),wide=b.call(compiler.ir.IrInlineEnumCaseAccess.HELPER_PREFIX+"forward",[access.construct(b,2,[floating,raw,type,callback])],Obj(mixed.valueObject.name));
   checks.push(b.equal(b.call(compiler.ir.IrScalarWordBits.PACK,[access.field(b,wide,2,1)],I64),b.call(compiler.ir.IrScalarWordBits.PACK,[raw],I64)));
   checks.push(b.equal(b.call(compiler.ir.IrScalarWordBits.PACK,[access.field(b,wide,2,2)],I64),b.call(compiler.ir.IrScalarWordBits.PACK,[type],I64)));
   checks.push(b.equal(access.field(b,wide,2,3),callback));
   checks.push(b.equal(b.call("__f64_to_i64_bits",[access.field(b,wide,2,0)],I64),b.call("__f64_to_i64_bits",[floating],I64)));
   for(index in 0...mixed.references)checks.push(b.equal(compiler.ir.IrInlineEnumReferenceAccess.read(b,wide,index,Obj("Source")),b.constNull(Obj("Source"))));
  }
  var bad=b.createBlock();for(check in checks){var next=b.createBlock();b.branch(check,next,bad);b.select(next);}b.returnValue(b.constInt(42));b.select(bad);b.returnValue(b.constInt(1));
  var p=new IrProgram("main");p.objects=objects;p.functions=[new IrFunction("main",b.arguments,I32,b.blocks, Ordinary)];p.natives=compiler.ir.IrInlineEnumWordAccess.natives();
  var relay=new IrBuilder(),input=relay.argument("value",Obj(mixed.valueObject.name)),output=relay.newObject(mixed.valueObject.name);
  for(field in mixed.valueObject.fields)relay.fieldSet(output,field.name,relay.fieldGet(input,field.name,field.type));
  relay.returnValue(output);p.functions.push(new IrFunction(compiler.ir.IrInlineEnumCaseAccess.HELPER_PREFIX+"relay",relay.arguments,Obj(mixed.valueObject.name),relay.blocks, Provider(compiler.ir.TypeKey.of(Obj(mixed.valueObject.name)), compiler.Provides.ProviderOperations.detailed(compiler.Provides.ProviderOperation.InlineEnumHelper, "relay"))));
  var forward=new IrBuilder(),input=forward.argument("value",Obj(mixed.valueObject.name));
  forward.returnValue(forward.call(compiler.ir.IrInlineEnumCaseAccess.HELPER_PREFIX+"relay",[input],Obj(mixed.valueObject.name)));
  p.functions.push(new IrFunction(compiler.ir.IrInlineEnumCaseAccess.HELPER_PREFIX+"forward",forward.arguments,Obj(mixed.valueObject.name),forward.blocks, Provider(compiler.ir.TypeKey.of(Obj(mixed.valueObject.name)), compiler.Provides.ProviderOperations.detailed(compiler.Provides.ProviderOperation.InlineEnumHelper, "forward"))));
  compiler.ir.IrVerifier.verify(p);
  // Raw host pointers are intentionally not interpreted in target-independent IR.
  p.functions=new compiler.ir.IrOptionalScalarFlow(p.objects).rewrite(p.objects,p.functions);
  p.functions=compiler.ir.IrOptionalValueFlow.addHelpers(p.functions,p.objects);
  compiler.ir.IrValueConstructors.rewrite(p);compiler.ir.IrValuePhiScalarization.rewrite(p);
  compiler.ir.IrScalarArguments.rewrite(p,target!=HashLink);
  var table=IrObjectTable.of([for(o in p.objects)o.name=>o]);
  p.functions=[for(fn in p.functions)compiler.ir.IrScalarReplacement.rewrite(fn,table,false,target==HashLink)];
  compiler.ir.IrNullableScalarFlow.rewrite(p);
  compiler.ir.IrInliner.run(p,new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm,inlineEnabled);
  compiler.ir.IrVerifier.verify(p);
  var entry=new IrBuilder(),censusPaths:Array<{path:String,count:Int}>=[];
  var result=entry.call("main",[],I32);
  if(target==HashLink) {
   p.natives.push({name:"censusStart",library:"std",symbol:"gc_census_start",arguments:[I32],result:Void});
   p.natives.push({name:"censusStop",library:"std",symbol:"gc_census_stop",arguments:[],result:Void});
   p.natives.push({name:"censusReset",library:"std",symbol:"gc_census_reset",arguments:[],result:Void});
   p.natives.push({name:"censusDump",library:"haxeon_runtime",symbol:"__gc_census_dump",arguments:[Bytes],result:Void});
   for(count in [8,1024]) {
    var path=tempRoot()+"/"+uniqueStem+"complete-case-probe-"+inlineEnabled+"-"+count+".json";censusPaths.push({path:path,count:count});
    entry.call("censusReset",[],Void);entry.call("censusStart",[entry.constInt(0)],Void);
    for(_ in 0...count)entry.call("main",[],I32);
    entry.call("censusStop",[],Void);entry.call("censusDump",[entry.constString(path)],Void);
   }
  }
  entry.call("__exit",[result],Void);entry.returnValue(entry.constVoid());p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks, Ordinary));
  p.natives.push({name:"__exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void});
  p.entryPoint=target==HashLink?"entry":"main";
  var backendTarget:compiler.backend.Backend.BackendTarget=target==HashLink?HashLink:target==Wasm32?Wasm32:WasmGc;
  var bytes=target==HashLink?new compiler.backend.hl.HlBackend().compile(p,{target:backendTarget,debugNames:true}).bytes:new compiler.backend.wasm.WasmBackend().compile(p,{target:backendTarget,debugNames:true,wasmGcAllocationCount:target==WasmGc,wasmMemoryStats:target==Wasm32}).bytes;
  var path=tempRoot()+"/"+uniqueStem+"complete-case-payload-probe-"+Std.string(target)+(target==HashLink?".hl":".wasm");sys.io.File.saveBytes(path,bytes);
  var js='const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;const count=e.__allocation_count||e["haxeon.memory.allocation_count"];for(const n of [8,1024]){const before=count();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("case result");const allocated=count()-before;if(allocated!==n)throw Error("extra enum payload boxes: "+allocated+" / "+n);}';
  var child=new sys.io.Process(target==HashLink?"scripts/hl":"node",target==HashLink?[path]:["-e",js,path]);var output=child.stdout.readAll().toString(),error=child.stderr.readAll().toString(),code=child.exitCode();child.close();sys.FileSystem.deleteFile(path);if(code!=(target==HashLink?42:0))throw Std.string(target)+" inline="+inlineEnabled+": "+code+" "+output+" "+error;
  for(capture in censusPaths) {
   var census:Dynamic=haxe.Json.parse(sys.io.File.getContent(capture.path));
   sys.FileSystem.deleteFile(capture.path);
   var unexpected:Array<String>=[];
   for(item in (census.types:Array<Dynamic>))if(item.type!="Source")unexpected.push(Std.string(item.type)+"="+item.count);
   if(census.allocations!=capture.count||unexpected.length!=0)throw "HashLink case boxes: "+census.allocations+" / "+capture.count+" "+unexpected.join(",");
   Sys.println("HashLink inline="+inlineEnabled+" exact census: "+census.allocations+" Source objects / "+capture.count+" calls");
  }
  Sys.println(Std.string(target)+" inline="+inlineEnabled+" direct cases passed");
 }
}
