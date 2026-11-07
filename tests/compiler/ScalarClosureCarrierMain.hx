import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrValueLaneReference;
import compiler.ir.IrScalarArguments;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
@:access(compiler.ir.IrBuilder)
class ScalarClosureCarrierMain {
 static function global(b:IrBuilder,name:String,type:IrType):IrValue {var v=b.temporary(type);b.emit(GlobalGet(v,name));return v;}
 static function runTargets():Void for(target in ([HashLink,Wasm32,WasmGc]:Array<IrValueLaneTarget>))for(inlineEnabled in [false,true])check(target,inlineEnabled);
 static function reject(label:String,build:IrProgram->Void,expected:String):Void {
  var p=new IrProgram("main");build(p);var message="";
  try compiler.ir.IrVerifier.verify(p) catch(error:Dynamic)message=Std.string(error);
  if(message.indexOf(expected)<0)throw label+": "+message;
  Sys.println("PASS: "+label);
 }
 static function checkVerifier():Void {
  var carrier=IrValueLaneReference.type(),name=IrScalarArguments.PREFIX+"callback",signature:IrType=Function([carrier],I32);
  var callee=new IrBuilder();callee.argument("value",carrier);callee.returnValue(callee.constInt(42));
  var b=new IrBuilder(),fn=b.staticClosure(name,signature);b.returnValue(b.callClosure(fn,[b.constNull(carrier)],I32));
  var p=new IrProgram("main");p.functions=[new IrFunction(name,callee.arguments,I32,callee.blocks),new IrFunction("main",b.arguments,I32,b.blocks)];
  compiler.ir.IrVerifier.verify(p);Sys.println("PASS: exact carrier argument through verified scalar closure");
  for(stack in [false,true])reject(stack?"native borrowing scalar prefix with stack reference":"native borrowing scalar prefix with carrier",function(p){
   var type:IrType=stack?compiler.ir.IrHlScalarRef.type(I32):carrier,signature:IrType=Function([type],I32);
   p.natives=[{name:name,library:"test",symbol:"not_verified",arguments:[type],result:I32}];
   var b=new IrBuilder();b.staticClosure(name,signature);b.returnValue(b.constInt(42));
   p.functions=[new IrFunction("main",b.arguments,I32,b.blocks)];
  },"A scalar closure must target a verified scalar function");
  reject("native prefix cannot consume a scalar stack reference directly",function(p){
   var type=compiler.ir.IrHlScalarRef.type(I32);p.natives=[{name:name,library:"test",symbol:"not_verified",arguments:[type],result:Void}];
   var b=new IrBuilder(),reference=b.call(compiler.ir.IrHlScalarRef.ADDRESS,[b.constInt(42)],type);b.call(name,[reference],Void);b.returnValue(b.constInt(42));
   p.functions=[new IrFunction("main",b.arguments,I32,b.blocks)];
  },"A scalar stack reference cannot escape its call");
  reject("carrier callable Dynamic escape",function(p){
   var c=new IrBuilder();c.argument("value",carrier);c.returnValue(c.constInt(42));
   var b=new IrBuilder();b.toDyn(b.staticClosure(name,signature));b.returnValue(b.constInt(42));
   p.functions=[new IrFunction(name,c.arguments,I32,c.blocks),new IrFunction("main",b.arguments,I32,b.blocks)];
  },"requires a logical Dynamic adapter");
  reject("carrier callable unchecked cast",function(p){
   var b=new IrBuilder();b.safeCast(b.constNull(Dyn),signature);b.returnValue(b.constInt(42));
   p.functions=[new IrFunction("main",b.arguments,I32,b.blocks)];
  },"requires a logical cast adapter");
  reject("one matching position cannot hide a mismatched repeated argument",function(p){
   var c=new IrBuilder();c.argument("value",carrier);c.argument("other",Dyn);c.returnValue(c.constInt(42));
   var b=new IrBuilder(),fn=b.staticClosure(name,Function([carrier,Dyn],I32)),value=b.constNull(carrier);
   b.returnValue(b.callClosure(fn,[value,value],I32));
   p.functions=[new IrFunction(name,c.arguments,I32,c.blocks),new IrFunction("main",b.arguments,I32,b.blocks)];
  },"Wrong IR closure argument type");
  reject("ordinary callable cannot consume a carrier",function(p){
   var b=new IrBuilder(),fn=b.argument("fn",Function([Dyn],I32));b.returnValue(b.callClosure(fn,[b.constNull(carrier)],I32));
   p.functions=[new IrFunction("main",b.arguments,I32,b.blocks)];
  },"A value lane reference cannot escape its operation");
 }
 static function main():Void {checkVerifier();runTargets();}
 static function check(target:IrValueLaneTarget,inlineEnabled:Bool):Void {
  var owner:IrObject={name:"CarrierClosureOwner",isValue:false,base:null,interfaces:[],methods:[],fields:[{name:"number",type:I32}]},
   carrier=IrValueLaneReference.type(),signature:IrType=Function([I32,carrier],I32),name=compiler.ir.IrScalarArguments.PREFIX+"carrier-callback";
  var p=new IrProgram("main");p.objects=[owner];p.staticFields=[{name:"owner",type:Obj(owner.name)},{name:"callback",type:signature}];
  var call=new IrBuilder(),tag=call.argument("tag",I32),reference=call.argument("reference",carrier),
   restored=call.call(IrValueLaneReference.UNPACK,[reference],Obj(owner.name));call.returnValue(call.add(tag,call.fieldGet(restored,"number",I32)));
  p.functions=[new IrFunction(name,call.arguments,I32,call.blocks)];
  var prepare=new IrBuilder(),value=prepare.newObject(owner.name);prepare.fieldSet(value,"number",prepare.constInt(40));
  prepare.emit(GlobalSet("owner",value));prepare.emit(GlobalSet("callback",prepare.staticClosure(name,signature)));prepare.returnValue(prepare.constVoid());
  p.functions.push(new IrFunction("prepare",prepare.arguments,Void,prepare.blocks,null,false,Expose));
  var b=new IrBuilder(),count=b.argument("count",I32),initial=b.currentBlock().id,start=b.constInt(0),header=b.createBlock(),body=b.createBlock(),done=b.createBlock(),
   indices:Array<IrPhiInput>=[{block:initial,value:start}],sums:Array<IrPhiInput>=[{block:initial,value:start}];
  b.jump(header);b.select(header);var index=b.phi(I32,indices),sum=b.phi(I32,sums);b.branch(b.less(index,count),body,done);b.select(body);
  var fn=global(b,"callback",signature),payload=b.call(IrValueLaneReference.PACK,[global(b,"owner",Obj(owner.name))],carrier),result=b.callClosure(fn,[b.constInt(2),payload],I32);
  indices.push({block:b.currentBlock().id,value:b.add(index,b.constInt(1))});sums.push({block:b.currentBlock().id,value:b.add(sum,result)});b.jump(header);b.select(done);b.returnValue(sum);
  p.functions.push(new IrFunction("perform",b.arguments,I32,b.blocks,null,false,Expose));
  var main=new IrBuilder();main.returnValue(main.constInt(42));p.functions.push(new IrFunction("main",main.arguments,I32,main.blocks));
  compiler.ir.IrInliner.run(p,new compiler.ir.IrInliner.IrInlineCache(),inlineEnabled);compiler.ir.IrVerifier.verify(p);
  var root=Sys.getEnv("TMPDIR");if(root==null)root="/tmp";var stem=root+"/scalar-carrier-closure-"+Std.random(0x7fffffff),captures:Array<String>=[];
  if(target==HashLink){
   p.natives=[{name:"major",library:"std",symbol:"gc_major",arguments:[],result:Void},
    {name:"start",library:"std",symbol:"gc_census_start",arguments:[I32],result:Void},
    {name:"stop",library:"std",symbol:"gc_census_stop",arguments:[],result:Void},
    {name:"reset",library:"std",symbol:"gc_census_reset",arguments:[],result:Void},
    {name:"dump",library:"haxeon_runtime",symbol:"__gc_census_dump",arguments:[Bytes],result:Void},
    {name:"exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void}];
   var entry=new IrBuilder(),bad=entry.createBlock();entry.call("prepare",[],Void);entry.call("major",[],Void);
   for(n in [8,1024]){
    var path=stem+"-"+n+".json";captures.push(path);entry.call("reset",[],Void);entry.call("start",[entry.constInt(0)],Void);
    var value=entry.call("perform",[entry.constInt(n)],I32);entry.call("stop",[],Void);entry.call("dump",[entry.constString(path)],Void);
    var next=entry.createBlock();entry.branch(entry.equal(value,entry.constInt(42*n)),next,bad);entry.select(next);
   }
   entry.call("exit",[entry.constInt(42)],Void);entry.returnValue(entry.constVoid());entry.select(bad);entry.call("exit",[entry.constInt(1)],Void);entry.returnValue(entry.constVoid());
   p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks));p.entryPoint="entry";
  }
  var backendTarget:compiler.backend.Backend.BackendTarget=target==HashLink?HashLink:target==Wasm32?Wasm32:WasmGc,
   bytes=target==HashLink?new compiler.backend.hl.HlBackend().compile(p,{target:backendTarget,debugNames:true}).bytes:
    new compiler.backend.wasm.WasmBackend().compile(p,{target:backendTarget,debugNames:true,wasmGcAllocationCount:target==WasmGc,wasmMemoryStats:target==Wasm32,wasmGcStress:target==Wasm32}).bytes,
   module=stem+(target==HashLink?".hl":".wasm");sys.io.File.saveBytes(module,bytes);
  var output="";
  try {
  var js='const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports,c=e.__allocation_count||e["haxeon.memory.allocation_count"];e.prepare();for(const n of [8,1024]){const before=c(),result=e.perform(n),allocated=c()-before;if(result!==42*n||allocated!==0)throw Error(JSON.stringify({n,result,allocated}));console.log(JSON.stringify({n,result,allocated}));}',
   child=new sys.io.Process(target==HashLink?"scripts/hl":"node",target==HashLink?[module]:["-e",js,module]),
   error=child.stderr.readAll().toString(),captured=child.stdout.readAll().toString(),status=child.exitCode();child.close();output=captured;
  if(status!=(target==HashLink?42:0))throw Std.string(target)+" inline="+inlineEnabled+" "+status+" "+error;
  for(path in captures){var data:Dynamic=haxe.Json.parse(sys.io.File.getContent(path));if(data.allocations!=0)throw "Carrier closure allocated "+data.allocations;}
  } catch(error:Dynamic){
   for(path in captures)if(sys.FileSystem.exists(path))sys.FileSystem.deleteFile(path);
   if(sys.FileSystem.exists(module))sys.FileSystem.deleteFile(module);
   throw error;
  }
  for(path in captures)sys.FileSystem.deleteFile(path);
  sys.FileSystem.deleteFile(module);
  Sys.println("PASS: "+target+" inline="+inlineEnabled+" exact carrier closure calls allocate zero at8/1024 "+output);
 }
}
