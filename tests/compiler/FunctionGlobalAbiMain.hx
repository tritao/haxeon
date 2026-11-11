import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlType;

/** Closure data globals must never use the VM's raw function-pointer slot initialization. */
@:access(compiler.ir.IrBuilder)
class FunctionGlobalAbiMain {
 static function isInt(type:HlTypeDef):Bool return switch type {case Simple(kind):kind==HlType.I32;default:false;};
 static function main():Void {
  var p=new IrProgram("main"),readType:IrType=Function([],I32),applyType:IrType=Function([I32],I32);
  p.staticFields=[{name:"read",type:readType},{name:"apply",type:applyType},{name:"number",type:I32}];
  var b=new IrBuilder(),read=b.temporary(readType);b.emit(GlobalGet(read,"read"));b.returnValue(b.callClosure(read,[],I32));
  p.functions=[new IrFunction("main",b.arguments,I32,b.blocks, None, [])];
  compiler.ir.IrVerifier.verify(p);
  var code=compiler.ir.hl.HlLower.lower(p,new Map()),readSignature=-1;
  for(index in 0...2)switch code.types[code.globals[index]] {
   case Parameterized(kind,parameter) if(kind==HlType.Null):switch code.types[parameter] {
    case Function(arguments,result):
     if(arguments.length!=index || !isInt(code.types[result]))throw "Function global lost its semantic signature";
     for(argument in arguments)if(!isInt(code.types[argument]))throw "Function global lost its argument type";
     if(index==0)readSignature=parameter;
    default:throw "Nullable closure storage lost its function type";
   }
   default:throw "Function data global uses the raw HFUN slot ABI";
  }
  if(!isInt(code.types[code.globals[2]]))throw "Scalar global storage changed";
  var typedRead=false;
  for(fn in code.functions)for(opcode in fn.opcodes)switch opcode {
   case GlobalGet(destination,0):
    if(fn.registers[destination]!=readSignature)throw "Closure register was erased or boxed to match its global slot";
    typedRead=true;
   default:
  }
  if(!typedRead)throw "Missing typed closure global read";
  Sys.println("PASS: closure globals use nullable typed reference slots; function registers retain their ABI");
 }
}
