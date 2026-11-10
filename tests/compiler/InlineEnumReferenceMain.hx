import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineEnumReferenceAccess;
import compiler.ir.IrValueLaneReference;
import compiler.ir.IrInterpreter;
import compiler.ir.IrVerifier;
@:access(compiler.ir.IrBuilder)
class InlineEnumReferenceMain {
 static function tempRoot():String { var root=Sys.getEnv("TMPDIR");return root==null?"/tmp":root; }
 static final uniqueStem="InlineEnumReferenceMain-"+Std.random(0x7fffffff)+"-";
 static function checkRejected(label:String,make:IrBuilder->IrValue,result:IrType,expected:String) {
  var b=new IrBuilder();b.returnValue(make(b));var p=new IrProgram("main");
  p.objects=[{name:"Source",isValue:false,base:null,interfaces:[],methods:[],fields:[{name:"code",type:I32}]}];
  p.functions=[new IrFunction("main",b.arguments,result,b.blocks, None)];
  var error="";try IrVerifier.verify(p)catch(e:Dynamic)error=Std.string(e);
  if(error.indexOf(expected)<0)throw "Verifier did not reject "+label+" with "+expected+": "+error;
 }
 static function main() {
  var b=new IrBuilder(), ref=b.newObject("Source"), owner=b.newObject("Payload");
  b.fieldSet(ref,"code",b.constInt(42));
  IrInlineEnumReferenceAccess.write(b,owner,0,ref);
  var restored=IrInlineEnumReferenceAccess.read(b,owner,0,Obj("Source"));
  var picked=b.call("pick",[ref,b.constBool(true)],Obj("Source")), cleared=b.call("pick",[ref,b.constBool(false)],Obj("Source"));
  var yes=b.createBlock(),no=b.createBlock(),next=b.createBlock(),next2=b.createBlock();
  b.branch(b.equal(picked,ref),next,no);b.select(next);
  b.branch(b.equal(cleared,b.constNull(Obj("Source"))),next2,no);b.select(next2);
  b.branch(b.equal(ref,restored),yes,no);
  b.select(yes);b.returnValue(b.fieldGet(restored,"code",I32));
  b.select(no);b.returnValue(b.constInt(1));
  var p=new IrProgram("main");
  p.objects=[{name:"Source",isValue:false,base:null,interfaces:[],methods:[],fields:[{name:"code",type:I32}]},
   {name:"Payload",isValue:true,base:null,interfaces:[],methods:[],fields:[{name:"reference0",type:IrValueLaneReference.type()}]}];
  p.functions=[new IrFunction("main",b.arguments,I32,b.blocks, None)];
  var pick=new IrBuilder(),arg=pick.argument("source",Obj("Source")),keep=pick.argument("keep",Bool),storage=pick.newObject("Payload");
  IrInlineEnumReferenceAccess.write(pick,storage,0,arg);
  var retained=pick.createBlock(),empty=pick.createBlock(),done=pick.createBlock();
  pick.branch(keep,retained,empty);
  pick.select(retained);var present=pick.fieldGet(storage,"reference0",IrValueLaneReference.type());pick.jump(done);
  pick.select(empty);pick.fieldSet(storage,"reference0",pick.constNull(IrValueLaneReference.type()));
  var absent=pick.fieldGet(storage,"reference0",IrValueLaneReference.type());pick.jump(done);
  pick.select(done);var selected=pick.phi(IrValueLaneReference.type(),[{block:retained.id,value:present},{block:empty.id,value:absent}]);
  pick.returnValue(pick.call(IrValueLaneReference.UNPACK,[selected],Obj("Source")));
  p.functions.push(new IrFunction("pick",pick.arguments,Obj("Source"),pick.blocks, None));
  var entry=new IrBuilder();entry.call("__exit",[entry.call("main",[],I32)],Void);entry.returnValue(entry.constVoid());
  p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks, None));
  p.natives=[{name:"__exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void}];
  IrVerifier.verify(p);
  var casts=0;
  for(fn in compiler.ir.hl.HlLower.lower(p).functions)for(op in fn.opcodes)switch op {case UnsafeCast(_,_):casts++;default:}
  if(casts!=4)throw "Reference leaves must use two non-boxing casts";
  checkRejected("Dynamic escape",function(b) return b.toDyn(b.constNull(IrValueLaneReference.type())),Dyn,"A value lane reference cannot escape its operation");
  checkRejected("function return",function(b) return b.constNull(IrValueLaneReference.type()),IrValueLaneReference.type(),"A value lane reference cannot be returned");
  checkRejected("mismatched field",function(b) { b.fieldGet(b.newObject("Source"),"code",IrValueLaneReference.type());return b.constInt(42); },I32,"Unknown or mismatched IR field");
  if(new IrInterpreter(p).run()!=42)throw "reference interpreter";
  for(target in [compiler.backend.Backend.BackendTarget.HashLink,compiler.backend.Backend.BackendTarget.Wasm32,compiler.backend.Backend.BackendTarget.WasmGc]) {
   p.entryPoint=target==HashLink?"entry":"main";
   var bytes=target==HashLink?new compiler.backend.hl.HlBackend().compile(p,{target:target,debugNames:true}).bytes:new compiler.backend.wasm.WasmBackend().compile(p,{target:target,debugNames:true,wasmGcAllocationCount:target==WasmGc,wasmMemoryStats:target==Wasm32}).bytes;
   var path=tempRoot()+"/"+uniqueStem+"reference-payload-"+Std.string(target)+(target==HashLink?".hl":".wasm");
   sys.io.File.saveBytes(path,bytes);
   var command=target==HashLink?"scripts/hl":"node";
   var js='const fs=require("fs");const e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;const count=e.__allocation_count||e["haxeon.memory.allocation_count"];const before=count();if(e.main()!==42)throw Error("reference payload");if(count()-before>1)throw Error("reference-slot box allocation: "+(count()-before));console.log(count()-before);';
   var child=new sys.io.Process(command,target==HashLink?[path]:["-e",js,path]);
   var output=child.stdout.readAll().toString(),error=child.stderr.readAll().toString(),code=child.exitCode();child.close();sys.FileSystem.deleteFile(path);
   if(code!=(target==HashLink?42:0))throw Std.string(target)+": "+code+" "+output+" "+error;
   if(target!=HashLink)Sys.println(Std.string(target)+" managed reference program allocations: "+StringTools.trim(output));
  }
  checkCollectedRoots();
  Sys.println("PASS: reference payload fields retain object identity and payload on all targets");
 }
 static function checkCollectedRoots():Void {
  for (target in [compiler.backend.Backend.BackendTarget.HashLink, compiler.backend.Backend.BackendTarget.Wasm32,
       compiler.backend.Backend.BackendTarget.WasmGc]) {
   var p = new IrProgram("checkRoot");
   p.objects = [
    {name:"RootSource",isValue:false,base:null,interfaces:[],methods:[],fields:[{name:"code",type:I32}]},
    {name:"RootPayload",isValue:true,base:null,interfaces:[],methods:[],fields:[{name:"reference0",type:IrValueLaneReference.type()}]}
   ];
   p.staticFields = [{name:"root",type:Obj("RootPayload")}];
   var prepare = new IrBuilder(), source = prepare.newObject("RootSource"), payload = prepare.newObject("RootPayload");
   prepare.fieldSet(source,"code",prepare.constInt(42));
   IrInlineEnumReferenceAccess.write(prepare,payload,0,source);
   prepare.emit(GlobalSet("root",payload)); prepare.returnValue(prepare.constVoid());
   var check = new IrBuilder(), saved = check.temporary(Obj("RootPayload"));
   check.emit(GlobalGet(saved,"root"));
   var restored = IrInlineEnumReferenceAccess.read(check,saved,0,Obj("RootSource"));
   check.returnValue(check.fieldGet(restored,"code",I32));
   p.functions = [
    new IrFunction("prepareRoot",prepare.arguments,Void,prepare.blocks, None,null,false,compiler.ir.IrFunction.IrRetention.Expose),
    new IrFunction("checkRoot",check.arguments,I32,check.blocks, None)
   ];
   if (target == HashLink) {
    p.natives = [
     {name:"major",library:"std",symbol:"gc_major",arguments:[],result:Void},
     {name:"__exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void}
    ];
    var entry = new IrBuilder(); entry.call("prepareRoot",[],Void); entry.call("major",[],Void);
    // The constructor's stack frame has gone. Reuse any incorrectly freed source slot.
    for (_ in 0...128) { var garbage=entry.newObject("RootSource");entry.fieldSet(garbage,"code",entry.constInt(-1)); }
    entry.call("major",[],Void);
    entry.call("__exit",[entry.call("checkRoot",[],I32)],Void); entry.returnValue(entry.constVoid());
    p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks, None)); p.entryPoint="entry";
   }
   IrVerifier.verify(p);
   var bytes = target == HashLink ? new compiler.backend.hl.HlBackend().compile(p,{target:target,debugNames:true}).bytes
    : new compiler.backend.wasm.WasmBackend().compile(p,{target:target,debugNames:true}).bytes;
   var path=tempRoot()+"/"+uniqueStem+"gc-roots-"+Std.string(target)+(target==HashLink?".hl":".wasm");
   sys.io.File.saveBytes(path,bytes);
   try {
    var js='const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports;e.prepareRoot();for(let i=0;i<3;i++)global.gc();if(e.main()!==42)throw Error("reference payload lost its only root");';
    var child=new sys.io.Process(target==HashLink?"scripts/hl":"node",target==HashLink?[path]:["--expose-gc","-e",js,path]);
    var out=child.stdout.readAll().toString(),err=child.stderr.readAll().toString(),code=child.exitCode();child.close();
    if(code!=(target==HashLink?42:0))throw Std.string(target)+" reference root: "+code+" "+out+" "+err;
   } catch (error:Dynamic) { sys.FileSystem.deleteFile(path);throw error; }
   sys.FileSystem.deleteFile(path);
  }
 }

}
