import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrTypedInterfaceDispatch;
import compiler.ir.IrVerifier;

class InterfaceValueDispatchMain {
 static function main():Void {
  var nested=compiler.ir.IrScalarArguments.PREFIX+compiler.ir.IrOptionalScalarFlow.PREFIX;
  if(!IrTypedInterfaceDispatch.isDispatchEntry(nested+IrTypedInterfaceDispatch.PREFIX+"Reader:read:key")
   || !IrTypedInterfaceDispatch.isAdapterEntry(nested+IrTypedInterfaceDispatch.adapterName(IrTypedInterfaceDispatch.PREFIX+"Reader:read:key","Owner")))
   throw "Optional value ABI entries lost their dispatch identity";
  var value:IrObject={name:"Value",isValue:true,base:null,interfaces:[],methods:[],fields:[{name:"number",type:I32}]};
  var owner:IrObject={name:"Owner",isValue:false,base:null,interfaces:["Derived"],fields:[{name:"value",type:Obj("Value")}],
   methods:[{name:"read",functionName:"Owner.read"},{name:"accept",functionName:"Owner.accept"},{name:"plain",functionName:"Owner.plain"}]};
  var interfaces:Array<IrInterface>=[{name:"Base",bases:[],methods:[
   {name:"read",arguments:[],result:Obj("Value")},{name:"accept",arguments:[Obj("Value")],result:Void},{name:"plain",arguments:[],result:I32}]},
   {name:"Derived",bases:["Base"],methods:[]}];
  var read=new IrBuilder(),self=read.argument("this",Obj("Owner"));read.returnValue(read.fieldGet(self,"value",Obj("Value")));
  var accept=new IrBuilder();accept.argument("this",Obj("Owner"));accept.argument("value",Obj("Value"));accept.returnValue(accept.constVoid());
  var plain=new IrBuilder();plain.argument("this",Obj("Owner"));plain.returnValue(plain.constInt(42));
  var b=new IrBuilder(),receiver=b.argument("reader",Virtual("Derived")),result=b.methodCall(receiver,"read",[],Obj("Value"));
  b.methodCall(receiver,"accept",[result],Void);b.instanceClosure("Base.read",receiver,Function([],Obj("Value")));
  b.instanceClosure("Base.accept",receiver,Function([Obj("Value")],Void));b.returnValue(b.methodCall(receiver,"plain",[],I32));
  var main=new IrFunction("main",b.arguments,I32,b.blocks, Ordinary),original=[
   new IrFunction("Owner.read",read.arguments,Obj("Value"),read.blocks, Ordinary),
   new IrFunction("Owner.accept",accept.arguments,Void,accept.blocks, Ordinary),
   new IrFunction("Owner.plain",plain.arguments,I32,plain.blocks, Ordinary),main];
  var rewritten=IrTypedInterfaceDispatch.rewriteValueCalls(original,[value,owner],interfaces);
  if(rewritten[0]!=original[0] || rewritten[3]==main)throw "Value interface rewrite did not preserve unchanged functions";
  var oldMethods=0,methods=0,calls=0,closures=0;
  for(block in main.blocks)for(located in block.instructions)switch located.value {case MethodCall(_,_,_,_,_):oldMethods++;default:}
  for(block in rewritten[3].blocks)for(located in block.instructions)switch located.value {
   case MethodCall(_,_,"plain",_,_):methods++;
   case Call(_,name,_) if(StringTools.startsWith(name,IrTypedInterfaceDispatch.PREFIX)):calls++;
   case InstanceClosure(_,name,_) if(StringTools.startsWith(name,IrTypedInterfaceDispatch.PREFIX)):closures++;
   default:
  }
  if(oldMethods!=3 || methods!=1 || calls!=2 || closures!=2)throw "Wrong direct/bound value-interface normalization";
  IrTypedInterfaceDispatch.generate(rewritten,[value,owner],interfaces);
  var length=rewritten.length;
  if(length!=original.length+4)throw "Direct and bound calls did not share their dispatchers";
  IrTypedInterfaceDispatch.generate(rewritten,[value,owner],interfaces);
  if(rewritten.length!=length)throw "Repeated dispatcher generation duplicated definitions";
  var p=new IrProgram("main");p.objects=[value,owner];p.interfaces=interfaces;p.functions=rewritten;
  p.natives=[{name:"__std_is_of_type",library:"haxeon_runtime",symbol:"__std_is_of_type",arguments:[Dyn,TypeRef],result:Bool}];
  IrVerifier.verify(p);
  var tables=new compiler.ir.hl.HlTypedInterfaceTables(p),entries=tables.entries.get("Owner");
  if(entries==null || entries.length!=2)throw "Missing per-class typed entries";
  var lowered=compiler.ir.hl.HlLower.lower(p),privateEntries=0;
  for(type in lowered.types)switch type {
   case Object(_,_,_,_,methods,_):for(method in methods)if(method.prototype==compiler.hl.HlCode.TYPED_METHOD_PROTOTYPE)privateEntries++;
   default:
  }
  if(privateEntries!=2)throw "HashLink typed entries were emitted as source methods";
  compiler.hl.HlValidator.validate(lowered);
  var stored=compiler.hl.persistence.HlTypeDefStateCodec.encode(lowered.types);
  var restored=compiler.hl.persistence.HlTypeDefStateCodec.decode(stored,lowered.strings.length,lowered.globals.length);
  if(compiler.hl.persistence.HlTypeDefStateCodec.encode(restored).compare(stored)!=0)throw "Private typed entries did not survive persistence";
  var bad=rewritten.copy();
  for(i in 0...bad.length)if(IrTypedInterfaceDispatch.isAdapterEntry(bad[i].name)) {
   var entry=bad[i];bad[i]=new IrFunction(entry.name,entry.arguments,Bool,entry.blocks, Ordinary);break;
  }
  var invalid=new IrProgram("main");invalid.functions=bad;invalid.objects=p.objects;invalid.interfaces=p.interfaces;
  var badRejected=false;try new compiler.ir.hl.HlTypedInterfaceTables(invalid) catch(error:Dynamic)badRejected=Std.string(error).indexOf("Invalid private typed interface entry")>=0;
  if(!badRejected)throw "Unchecked typed method ABI was accepted";
  // Candidate discovery must be fresh even when an existing dispatcher has the same signature.
  IrTypedInterfaceDispatch.generate(rewritten,[value],interfaces);
  for(fn in rewritten)if(StringTools.startsWith(fn.name,IrTypedInterfaceDispatch.PREFIX))for(block in fn.blocks)for(located in block.instructions)
   switch located.value {case Call(_,name,_) if(name=="Owner.read" || name=="Owner.accept" || IrTypedInterfaceDispatch.isAdapterEntry(name)):throw "Regeneration retained a removed implementation";default:}
  IrTypedInterfaceDispatch.generate(rewritten,[value,owner],interfaces);
  var index=-1;for(i in 0...rewritten.length)if(StringTools.startsWith(rewritten[i].name,IrTypedInterfaceDispatch.PREFIX)){index=i;break;}
  if(index<0)throw "Missing dispatcher definition";
  var existing=rewritten[index];
  rewritten[index]=new IrFunction(existing.name,existing.arguments,Bool,existing.blocks, Ordinary);
  var rejected=false;try IrTypedInterfaceDispatch.generate(rewritten,[value,owner],interfaces) catch(error:Dynamic) {
   rejected=Std.string(error).indexOf("Conflicting typed interface dispatch")>=0;
  }
  if(!rejected)throw "Stale dispatcher signature was accepted";
  Sys.println("PASS: value interface calls and bound inherited methods share typed dispatch; cached IR remains unchanged and regeneration is checked");
 }
}
