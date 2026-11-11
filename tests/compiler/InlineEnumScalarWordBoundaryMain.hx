import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrScalarWordBits;
class InlineEnumScalarWordBoundaryMain {
 static function tempRoot():String { var root=Sys.getEnv("TMPDIR");return root==null?"/tmp":root; }
 static final uniqueStem="InlineEnumScalarWordBoundaryMain-"+Std.random(0x7fffffff)+"-";
 static function reject(label:String,create:IrBuilder->Void,expected:String):Void {
  var b=new IrBuilder();create(b);b.returnValue(b.constInt(42));var p=new IrProgram("main");
  p.objects=[{name:"Owner",isValue:false,base:null,interfaces:[],methods:[],fields:[]}];p.functions=[new IrFunction("main",b.arguments,I32,b.blocks, Ordinary)];
  var error="";try compiler.ir.IrVerifier.verify(p)catch(e:Dynamic)error=Std.string(e);
  if(error.indexOf(expected)<0)throw label+": "+error;
  Sys.println("PASS: rejects "+label);
 }
 static function main():Void {
  reject("managed object in scalar word",b->{b.call(IrScalarWordBits.PACK,[b.newObject("Owner")],I64);},"Invalid scalar word transport signature");
  reject("Dynamic in scalar word",b->{b.call(IrScalarWordBits.PACK,[b.constNull(Dyn)],I64);},"Invalid scalar word transport signature");
  reject("scalar bits decoded as managed object",b->{b.call(IrScalarWordBits.UNPACK,[b.constInt(0,I64)],Obj("Owner"));},"Invalid scalar word transport signature");
  reject("wrong scalar word arity",b->{b.call(IrScalarWordBits.PACK,[],I64);},"Invalid scalar word transport signature");
  reject("word transport as C native",b->{b.cNativeCall(IrScalarWordBits.UNPACK,[b.constInt(0,I64)],RawPtr);},"Scalar word transport is not a C native");
  var b=new IrBuilder();b.call(IrScalarWordBits.PACK,[b.constNull(Abstract("native_callback"))],I64);b.returnValue(b.constInt(42));
  var p=new IrProgram("main");p.functions=[new IrFunction("main",b.arguments,I32,b.blocks, Ordinary)];compiler.ir.IrVerifier.verify(p);
  var error="";try compiler.ir.hl.HlLower.lower(p)catch(e:Dynamic)error=Std.string(e);
  if(error.indexOf("HashLink callbacks belong in the reference lane")<0)throw "HashLink callback word escape: "+error;
  Sys.println("PASS: HashLink callback handles cannot enter scalar words");
 }
}
