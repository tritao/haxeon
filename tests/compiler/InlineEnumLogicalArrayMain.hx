import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrValueLaneReference;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
/** Logical enum array descriptors with private lanes; source enum activation remains separate. */
@:access(compiler.ir.IrBuilder)
class InlineEnumLogicalArrayMain {
 static function tempRoot():String { var root=Sys.getEnv("TMPDIR");return root==null?"/tmp":root; }
 static final uniqueStem="InlineEnumLogicalArrayMain-"+Std.random(0x7fffffff)+"-";
 static function global(b:IrBuilder,name:String,type:IrType):IrValue { var value=b.temporary(type);b.emit(GlobalGet(value,name));return value; }
 static function main():Void {
  for (inlineEnabled in [false,true]) for(target in [HashLink,Wasm32,WasmGc])check(target,inlineEnabled);
 }
 static function check(target:IrValueLaneTarget,inlineEnabled:Bool):Void {
  var owner:IrObject={name:"Owner",isValue:false,base:null,interfaces:[],methods:[],fields:[{name:"code",type:I32}]};
  var declaration:IrEnum={name:"Element",cases:[{name:"Empty",params:[]},{name:"Data",params:[I32,Obj("Owner")]}]};
  var planner=new compiler.ir.IrInlineEnumLayout([declaration],[owner],target==HashLink?64:32,target),packet=planner.shape("Element").valueObject;
  var declarations:Array<IrEnum>=[{name:declaration.name,cases:declaration.cases,inlineStorage:packet.name}];
  var table=compiler.ir.IrObjectTable.of([owner.name=>owner,packet.name=>packet]),type:IrType=Enum("Element"),arrayType:IrType=Array(type);
  var factory=new compiler.ir.IrValueArrayFactory(table,type,target==HashLink?64:32,target,0,declarations),helpers=factory.helpers;
  var elements=new compiler.ir.IrValueArrayElements(type,helpers,factory.bridge);elements.useIterator();
  var prepare=new IrBuilder(),reference=prepare.newObject("Owner"),shape=factory.layout.lanes;
  prepare.fieldSet(reference,"code",prepare.constInt(42));
  var array=prepare.call("__array_alloc_ref",[prepare.constInt(1)],arrayType);
  prepare.call(helpers.setter(helpers.slot(["tag"])),[array,prepare.constInt(0),prepare.constInt(2)],Void);
  prepare.call(helpers.setter(helpers.slot(["reference0"])),[array,prepare.constInt(0),prepare.call(IrValueLaneReference.PACK,[reference],IrValueLaneReference.type())],Void);
  prepare.call("__value_array_mark",[array,prepare.constInt(0)],Void);
  prepare.emit(GlobalSet("array",array));prepare.returnValue(prepare.constVoid());
  var b=new IrBuilder(),array=global(b,"array",arrayType),reference=b.call(IrValueLaneReference.UNPACK,[b.call(helpers.getter(helpers.slot(["reference0"])),[array,b.constInt(0)],IrValueLaneReference.type())],Obj("Owner")),index=b.constInt(0),carrier=b.call(IrValueLaneReference.PACK,[reference],IrValueLaneReference.type());
  b.call(helpers.setter(helpers.slot(["tag"])),[array,index,b.constInt(2)],Void);
  b.call(helpers.setter(helpers.slot(["reference0"])),[array,index,carrier],Void);
  b.call("__value_array_mark",[array,index],Void);
  var loaded=b.call(helpers.getter(helpers.slot(["reference0"])),[array,index],IrValueLaneReference.type());
  var restored=b.call(IrValueLaneReference.UNPACK,[loaded],Obj("Owner")),yes=b.createBlock(),no=b.createBlock();
  var copy=b.temporary(Obj(packet.name));b.emit(ArrayGet(copy,array,index));b.fieldSet(copy,"scalar0",b.constInt(99));
  var original=b.call(helpers.getter(helpers.slot(["scalar0"])),[array,index],I32),copyOK=b.createBlock();
  b.branch(b.equal(original,b.constInt(37)),copyOK,no);b.select(copyOK);
  b.emit(ArraySet(array,index,copy));b.fieldSet(copy,"scalar0",b.constInt(37));b.emit(ArraySet(array,index,copy));
  b.branch(b.equal(b.fieldGet(restored,"code",I32),b.constInt(42)),yes,no);b.select(yes);b.returnValue(b.constInt(42));b.select(no);b.returnValue(b.constInt(1));
  var p=new IrProgram("main");p.objects=[owner,packet];p.enums=declarations;
  p.staticFields=[{name:"array",type:arrayType},{name:"unrelatedOptional",type:Nullable(I32)}];
  // A recursive declaration in the same program remains boxed and keeps reference-array operations.
  p.enums.push({name:"BoxedElement",cases:[{name:"Empty",params:[]},{name:"Next",params:[Enum("BoxedElement")]}],isRecursive:true});
  p.functions=[new IrFunction("prepare",prepare.arguments,Void,prepare.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose),new IrFunction("main",b.arguments,I32,b.blocks, Ordinary)];
  var boxedRead=new IrBuilder(),boxedArray=boxedRead.argument("array",Array(Enum("BoxedElement"))),boxedValue=boxedRead.temporary(Enum("BoxedElement"));
  boxedRead.emit(ArrayGet(boxedValue,boxedArray,boxedRead.constInt(0)));boxedRead.returnValue(boxedValue);
  p.functions.push(new IrFunction("boxedRead",boxedRead.arguments,Enum("BoxedElement"),boxedRead.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose));
  var mutation=new IrBuilder(),mutationOwner=mutation.newObject("Owner");mutation.fieldSet(mutationOwner,"code",mutation.constInt(42));
  var mutationValue=new compiler.ir.IrInlineEnumCaseAccess(planner.shape("Element"),table).construct(mutation,1,[mutation.constInt(37),mutationOwner]),
   mutationArray=mutation.call("__array_alloc_ref",[mutation.constInt(1)],arrayType);
  mutation.emit(ArraySet(mutationArray,mutation.constInt(0),mutationValue));
  mutation.call("__array_push_ref",[mutationArray,mutationValue],I32);
  mutation.call("__array_unshift_ref",[mutationArray,mutationValue],I32);
  mutation.call("__array_insert_ref",[mutationArray,mutation.constInt(1),mutationValue],Void);
  var popped=mutation.call("__array_pop_ref",[mutationArray],Obj(packet.name)),shifted=mutation.call("__array_shift_ref",[mutationArray],Obj(packet.name)),
   mutationGood=mutation.createBlock(),mutationBad=mutation.createBlock(),mutationDone=mutation.createBlock();
  mutation.branch(mutation.equal(mutation.fieldGet(popped,"scalar0",I32),mutation.constInt(37)),mutationGood,mutationBad);mutation.select(mutationGood);
  mutation.branch(mutation.equal(mutation.fieldGet(shifted,"scalar0",I32),mutation.constInt(37)),mutationDone,mutationBad);mutation.select(mutationDone);
  var mutationLength=mutation.temporary(I32);mutation.emit(ArraySize(mutationLength,mutationArray));mutation.returnValue(mutation.add(mutationLength,mutation.constInt(40)));mutation.select(mutationBad);mutation.returnValue(mutation.constInt(1));
  p.functions.push(new IrFunction("mutationCheck",mutation.arguments,I32,mutation.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose));
  var dynamicCheck=new IrBuilder(),dynamicArray=global(dynamicCheck,"array",arrayType),zero=dynamicCheck.constInt(0);
  var savedOwner=dynamicCheck.call(IrValueLaneReference.UNPACK,[dynamicCheck.call(helpers.getter(helpers.slot(["reference0"])),[dynamicArray,zero],IrValueLaneReference.type())],Obj("Owner"));
  dynamicCheck.call("__array_set_any",[dynamicArray,zero,dynamicCheck.constNull(Dyn)],Void);
  var empty=dynamicCheck.call("__array_get_any",[dynamicArray,zero],Dyn),good=dynamicCheck.createBlock(),bad=dynamicCheck.createBlock();
  dynamicCheck.branch(dynamicCheck.equal(empty,dynamicCheck.constNull(Dyn)),good,bad);dynamicCheck.select(good);
  var caseAccess=new compiler.ir.IrInlineEnumCaseAccess(planner.shape("Element"),table);
  var boxed=dynamicCheck.call(compiler.ir.IrInlineEnumEscapes.boxName("Element"),[caseAccess.construct(dynamicCheck,1,[dynamicCheck.constInt(37),savedOwner])],Dyn);
  dynamicCheck.call("__array_set_any",[dynamicArray,zero,boxed],Void);
  var escaped=dynamicCheck.call(compiler.ir.IrInlineEnumEscapes.unboxName("Element"),[dynamicCheck.call("__array_get_any",[dynamicArray,zero],Dyn)],Obj(packet.name)),number=caseAccess.field(dynamicCheck,escaped,1,0);
  // Simulate a native producer's ordinary Array<Enum>, then migrate it without changing aliases.
  var nativeArray=dynamicCheck.call("__array_alloc_typed_ref",[dynamicCheck.constInt(1),dynamicCheck.typeValue(type)],arrayType);
  dynamicCheck.call("__array_set_any",[nativeArray,zero,boxed],Void);
  var migrated=dynamicCheck.call(factory.retypeName(),[nativeArray],arrayType);
  var migratedValue=dynamicCheck.call(compiler.ir.IrInlineEnumEscapes.unboxName("Element"),[dynamicCheck.call("__array_get_any",[migrated,zero],Dyn)],Obj(packet.name)),migratedNumber=caseAccess.field(dynamicCheck,migratedValue,1,0);
  var migratedOK=dynamicCheck.createBlock();dynamicCheck.branch(dynamicCheck.equal(migratedNumber,dynamicCheck.constInt(37)),migratedOK,bad);dynamicCheck.select(migratedOK);
  var emptyCase=dynamicCheck.call(compiler.ir.IrInlineEnumEscapes.boxName("Element"),[caseAccess.construct(dynamicCheck,0,[])],Dyn);
  dynamicCheck.call("__array_set_any",[nativeArray,zero,emptyCase],Void);
  var aliasTag=dynamicCheck.call(helpers.getter(helpers.slot(["tag"])),[migrated,zero],I32),aliasOK=dynamicCheck.createBlock();
  dynamicCheck.branch(dynamicCheck.equal(aliasTag,dynamicCheck.constInt(1)),aliasOK,bad);dynamicCheck.select(aliasOK);
  var done=dynamicCheck.createBlock();dynamicCheck.branch(dynamicCheck.equal(number,dynamicCheck.constInt(37)),done,bad);dynamicCheck.select(done);dynamicCheck.returnValue(dynamicCheck.constInt(42));dynamicCheck.select(bad);dynamicCheck.returnValue(dynamicCheck.constInt(1));
  p.functions.push(new IrFunction("dynamicCheck",dynamicCheck.arguments,I32,dynamicCheck.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose));
  var build=new IrBuilder(),count=build.argument("count",I32),baseArray=global(build,"array",arrayType);
  var ownerValue=build.call(IrValueLaneReference.UNPACK,[build.call(helpers.getter(helpers.slot(["reference0"])),[baseArray,build.constInt(0)],IrValueLaneReference.type())],Obj("Owner"));
  var outputArray=build.call("__array_alloc_ref",[count],arrayType),initial=build.currentBlock(),fill=build.createBlock(),fillBody=build.createBlock(),filled=build.createBlock(),start=build.constInt(0);
  build.jump(fill);build.select(fill);var indices:Array<IrPhiInput>=[{block:initial.id,value:start}],position=build.phi(I32,indices);
  build.branch(build.less(position,count),fillBody,filled);build.select(fillBody);
  var caseAccess=new compiler.ir.IrInlineEnumCaseAccess(planner.shape("Element"),table),value=caseAccess.construct(build,1,[build.constInt(37),ownerValue]);
  build.emit(ArraySet(outputArray,position,value));var nextPosition=build.add(position,build.constInt(1));indices.push({block:build.currentBlock().id,value:nextPosition});build.jump(fill);
  build.select(filled);var iterator=build.temporary(Iterator(type));build.emit(IteratorNew(iterator,outputArray));var readStart=build.currentBlock(),read=build.createBlock(),readBody=build.createBlock(),doneRead=build.createBlock(),zeroRead=build.constInt(0);
  build.jump(read);build.select(read);var reads:Array<IrPhiInput>=[{block:readStart.id,value:zeroRead}],sums:Array<IrPhiInput>=[{block:readStart.id,value:zeroRead}],readIndex=build.phi(I32,reads),sum=build.phi(I32,sums);
  build.branch(build.less(readIndex,count),readBody,doneRead);build.select(readBody);
  var entryValue=build.temporary(Obj(packet.name));build.emit(IteratorNext(entryValue,iterator));var nextSum=build.add(sum,build.fieldGet(entryValue,"scalar0",I32)),nextRead=build.add(readIndex,build.constInt(1));
  reads.push({block:build.currentBlock().id,value:nextRead});sums.push({block:build.currentBlock().id,value:nextSum});build.jump(read);build.select(doneRead);build.returnValue(sum);
  p.functions.push(new IrFunction("buildAndIterate",build.arguments,I32,build.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose));
  var churn=new IrBuilder();for(_ in 0...128){var garbage=churn.newObject("Owner");churn.fieldSet(garbage,"code",churn.constInt(-1));}churn.returnValue(churn.constVoid());
  p.functions.push(new IrFunction("churn",churn.arguments,Void,churn.blocks, Ordinary,null,false,compiler.ir.IrFunction.IrRetention.Expose));
  p.functions=p.functions.concat(compiler.ir.IrInlineEnumEscapes.functions(declarations,table,planner));
  // The manually built calls above own their helper definitions; the program rewrite creates its own helpers.
  p.functions=p.functions.concat(helpers.functions());
  p.natives=compiler.ir.IrInlineEnumWordAccess.natives();p.natives.push({name:"__array_set_any",library:"haxeon_runtime",symbol:"__array_set_any",arguments:[Array(Dyn),I32,Dyn],result:Void});p.natives.push({name:"__array_get_any",library:"haxeon_runtime",symbol:"__array_get_any",arguments:[Array(Dyn),I32],result:Dyn});p.natives.push({name:"__array_alloc_typed_ref",library:"haxeon_runtime",symbol:"__array_alloc_typed_ref",arguments:[I32,TypeRef],result:arrayType});
  p.natives=p.natives.concat(helpers.natives());
  compiler.ir.IrProgramAssembler.ensureArrayRuntime(p,false,false,false);
  compiler.ir.IrValueArrayProgramRewrite.rewriteAll(p,target==HashLink?64:32,target);
  var boxedStillUsesReferences=false;
  for(fn in p.functions)if(fn.name=="boxedRead")for(block in fn.blocks)for(item in block.instructions)switch item.value {case ArrayGet(_,_,_):boxedStillUsesReferences=true;default:}
  if(!boxedStillUsesReferences)throw "Recursive enum array was incorrectly converted to lane storage";
  for(iteratorRead in [false,true]){
   var invalid=new IrBuilder(),container=invalid.argument("container",iteratorRead?Iterator(type):arrayType),out=invalid.temporary(type);
   if(iteratorRead)invalid.emit(IteratorNext(out,container));else invalid.emit(ArrayGet(out,container,invalid.constInt(0)));
   invalid.returnValue(out);var rejected=false;
   try compiler.ir.IrValueArrayElementRewrite.rewrite(new IrFunction("invalid",invalid.arguments,type,invalid.blocks, Ordinary),type,elements)
   catch(error:Dynamic){if(Std.string(error).indexOf("Wrong inline array")<0)throw error;rejected=true;}
   if(!rejected)throw "Logical enum used in place of physical element storage";
  }
  compiler.ir.IrValueConstructors.rewrite(p);compiler.ir.IrValuePhiScalarization.rewrite(p);compiler.ir.IrScalarArguments.rewrite(p,target!=HashLink);
  var scalarObjects=compiler.ir.IrObjectTable.of([for(object in p.objects)object.name=>object]);
  p.functions=[for(fn in p.functions)compiler.ir.IrScalarReplacement.rewrite(fn,scalarObjects,false,target==HashLink)];
  compiler.ir.IrNullableScalarFlow.rewrite(p);
  compiler.ir.IrInliner.run(p,new compiler.ir.IrInliner.IrInlineCache(), compiler.ir.TargetProfile.wasm,inlineEnabled);
  compiler.ir.IrVerifier.verify(p);compiler.ir.IrVerifier.verifyValueArraysLowered(p);
  var entry=new IrBuilder(),captures:Array<{path:String,count:Int,build:Bool}>=[];
  entry.call("prepare",[],Void);
  if(target==HashLink){p.natives.push({name:"major",library:"std",symbol:"gc_major",arguments:[],result:Void});entry.call("major",[],Void);entry.call("churn",[],Void);entry.call("major",[],Void);}
  var mutationResult=entry.call("mutationCheck",[],I32);
  var dynamicResult=entry.call("dynamicCheck",[],I32),mainResult=entry.call("main",[],I32),result=entry.sub(entry.add(entry.add(dynamicResult,mainResult),mutationResult),entry.constInt(84));
  if(target==HashLink) {
   p.natives=p.natives.concat([{name:"start",library:"std",symbol:"gc_census_start",arguments:[I32],result:Void},{name:"stop",library:"std",symbol:"gc_census_stop",arguments:[],result:Void},{name:"reset",library:"std",symbol:"gc_census_reset",arguments:[],result:Void},{name:"dump",library:"haxeon_runtime",symbol:"__gc_census_dump",arguments:[Bytes],result:Void}]);
   for(n in [8,1024]) {
    var path=tempRoot()+"/"+uniqueStem+"carrier-array-"+n+".json";captures.push({path:path,count:n,build:false});
    entry.call("reset",[],Void);entry.call("start",[entry.constInt(0)],Void);for(_ in 0...n)entry.call("main",[],I32);entry.call("stop",[],Void);entry.call("dump",[entry.constString(path)],Void);
   }
   for(n in [8,1024]) {
    var path=tempRoot()+"/"+uniqueStem+"build-array-"+n+".json";captures.push({path:path,count:n,build:true});
    entry.call("reset",[],Void);entry.call("start",[entry.constInt(0)],Void);
    var built=entry.call("buildAndIterate",[entry.constInt(n)],I32);
    entry.call("stop",[],Void);entry.call("dump",[entry.constString(path)],Void);
    result=entry.add(result,entry.sub(built,entry.constInt(37*n)));
   }
  }
  p.natives.push({name:"__exit",library:"std",symbol:"sys_exit",arguments:[I32],result:Void});entry.call("__exit",[result],Void);entry.returnValue(entry.constVoid());
  p.functions.push(new IrFunction("entry",entry.arguments,Void,entry.blocks, Ordinary));p.entryPoint=target==HashLink?"entry":"main";
  var targetBackend:compiler.backend.Backend.BackendTarget=target==HashLink?HashLink:target==Wasm32?Wasm32:WasmGc;
  var bytes=target==HashLink?new compiler.backend.hl.HlBackend().compile(p,{target:targetBackend,debugNames:true}).bytes:new compiler.backend.wasm.WasmBackend().compile(p,{target:targetBackend,debugNames:true,wasmGcAllocationCount:target==WasmGc,wasmMemoryStats:target==Wasm32,wasmGcStress:target==Wasm32}).bytes;
  var path=tempRoot()+"/"+uniqueStem+"carrier-array-"+Std.string(target)+(target==HashLink?".hl":".wasm");sys.io.File.saveBytes(path,bytes);
  var js='const fs=require("fs"),e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports,c=e.__allocation_count||e["haxeon.memory.allocation_count"];e.prepare();const collections=e["haxeon.memory.collection_count"],beforeGC=collections?collections():0;global.gc();e.churn();global.gc();if(collections&&collections()<=beforeGC)throw Error("guest did not collect");if(e.dynamicCheck()!==42||e.mutationCheck()!==42)throw Error("dynamic or typed enum array");e.main();for(const n of [8,1024]){const before=c();for(let i=0;i<n;i++)if(e.main()!==42)throw Error("result");if(c()!==before)throw Error("carrier array boxing: "+(c()-before));}let allocationSlope;for(const n of [8,1024]){const before=c();if(e.buildAndIterate(n)!==37*n)throw Error("iteration result");const allocations=c()-before;if(allocationSlope!==undefined&&allocations!==allocationSlope)throw Error("per-element construction boxing: "+allocationSlope+" -> "+allocations);allocationSlope=allocations;}';
  var child=new sys.io.Process(target==HashLink?"scripts/hl":"node",target==HashLink?[path]:["--expose-gc","-e",js,path]);var output=child.stdout.readAll().toString(),error=child.stderr.readAll().toString(),code=child.exitCode();child.close();sys.FileSystem.deleteFile(path);
  if(code!=(target==HashLink?42:0))throw Std.string(target)+": "+code+" "+output+" "+error;
  var buildAllocations:Null<Int>=null;
  for(capture in captures){var census:Dynamic=haxe.Json.parse(sys.io.File.getContent(capture.path));sys.FileSystem.deleteFile(capture.path);if(capture.build){if(buildAllocations!=null&&buildAllocations!=census.allocations)throw "Per-element construction allocation: "+buildAllocations+" -> "+census.allocations;buildAllocations=census.allocations;}else if(census.allocations!=0)throw "Carrier array allocation: "+census.allocations;}
  Sys.println("PASS: "+Std.string(target)+" logical enum array descriptors, typed copies and Dynamic/native round trips; zero typed allocations at 8/1024 calls");
 }
}
