interface EnumOffset { function offset():Int; }
interface EnumTransform extends EnumOffset { function apply(value:Int):Int; }
interface EnumGeneric<T> { function convert(value:T):T; }
class EnumCalls { public static var count:Int = 0; }
enum EnumOperation implements EnumTransform {
 Add(amount:Int);
 public function offset():Int return 1;
 public function apply(value:Int):Int return value + this.offset();
}
enum EnumIdentity implements EnumGeneric<Int> {
 Identity;
 public function convert(value:Int):Int return value;
}
function applyGeneric<T:EnumTransform>(operation:T):Int return operation.apply(41);
function applyInterface(operation:EnumTransform):Int return operation.apply(41);
function applyGenericInterface(operation:EnumGeneric<Int>):Int return operation.convert(42);
function nullableFactory():Null<EnumOperation> { EnumCalls.count++; return Add(1); }
function nullableInterface(operation:Null<EnumTransform>):Int return operation == null ? 0 : operation.apply(41);
function main():Int {
 var value:EnumOperation = Add(1);
 if (value.offset() != 1 || value.apply(41) != 42) return 1;
 if (applyInterface(value) != 42) return 2;
 if (applyGenericInterface(Identity) != 42) return 3;
 if (nullableInterface(nullableFactory()) != 42 || EnumCalls.count != 1) return 4;
 return applyGeneric(value);
}
