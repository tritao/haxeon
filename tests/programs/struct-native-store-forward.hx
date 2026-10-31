struct Narrow {
  public var signed:Int16;
  public var unsigned:UInt8;
  public function new() { signed = 0; unsigned = 0; }
}
struct Fraction {
  public var value:Float32;
  public function new() value = cast 0.0;
}
struct ManagedFraction {
  public var value:Float32;
  public var text:String;
  public function new() { value = cast 0.0; text = "managed"; }
}
function update(value:Narrow):Int {
  try {
    value.signed = cast 65535;
    value.unsigned = cast 257;
    return (cast value.signed:Int) * 10 + (cast value.unsigned:Int);
  } catch (_:Dynamic) return 2;
}
function fraction(value:Fraction):Float {
  try { value.value = cast 16777217.0; return cast value.value; }
  catch (_:Dynamic) return 0;
}
function managedFraction(value:ManagedFraction):Float {
  try { value.value = cast 16777217.0; return cast value.value; }
  catch (_:Dynamic) return 0;
}
function main():Int {
  if (update(new Narrow()) != -9) return 1;
  if (fraction(new Fraction()) != 16777216.0) return 2;
  if (managedFraction(new ManagedFraction()) != 16777216.0) return 3;
  return 42;
}
