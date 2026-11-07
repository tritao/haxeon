class DispatchOwner { public final number:Int; public function new() number=40; }
struct DispatchPacket { public final number:Int; public final owner:DispatchOwner; public function new(number:Int,owner:DispatchOwner){this.number=number;this.owner=owner;} }
interface DispatchReader { function read():DispatchPacket; function plain():Int; }
interface DispatchInherited extends DispatchReader {}
class DispatchBase implements DispatchInherited {
 public final owner:DispatchOwner; public function new() owner=new DispatchOwner();
 public function read():DispatchPacket return new DispatchPacket(2,owner);
 public function plain():Int return 7;
}
class DispatchImpl01 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(3,owner); }
class DispatchImpl02 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(4,owner); }
class DispatchImpl03 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(5,owner); }
class DispatchImpl04 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(6,owner); }
class DispatchImpl05 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(7,owner); }
class DispatchImpl06 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(8,owner); }
class DispatchImpl07 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(9,owner); }
class DispatchImpl08 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(10,owner); }
class DispatchImpl09 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(11,owner); }
class DispatchImpl10 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(12,owner); }
class DispatchImpl11 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(13,owner); }
class DispatchImpl12 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(14,owner); }
class DispatchImpl13 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(15,owner); }
class DispatchImpl14 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(16,owner); }
class DispatchImpl15 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(17,owner); }
class DispatchImpl16 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(18,owner); }
class DispatchImpl17 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(19,owner); }
class DispatchImpl18 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(20,owner); }
class DispatchImpl19 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(21,owner); }
class DispatchImpl20 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(22,owner); }
class DispatchImpl21 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(23,owner); }
class DispatchImpl22 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(24,owner); }
class DispatchImpl23 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(25,owner); }
class DispatchImpl24 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(26,owner); }
class DispatchImpl25 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(27,owner); }
class DispatchImpl26 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(28,owner); }
class DispatchImpl27 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(29,owner); }
class DispatchImpl28 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(30,owner); }
class DispatchImpl29 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(31,owner); }
class DispatchImpl30 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(32,owner); }
class DispatchImpl31 extends DispatchBase { public function new() super(); public override function read():DispatchPacket return new DispatchPacket(33,owner); }
class DispatchCheck {
 public static function receiver(kind:Int):DispatchInherited {
  return switch kind {
   case 0: new DispatchBase();
   case 1: new DispatchImpl01();
   case 2: new DispatchImpl02();
   case 3: new DispatchImpl03();
   case 4: new DispatchImpl04();
   case 5: new DispatchImpl05();
   case 6: new DispatchImpl06();
   case 7: new DispatchImpl07();
   case 8: new DispatchImpl08();
   case 9: new DispatchImpl09();
   case 10: new DispatchImpl10();
   case 11: new DispatchImpl11();
   case 12: new DispatchImpl12();
   case 13: new DispatchImpl13();
   case 14: new DispatchImpl14();
   case 15: new DispatchImpl15();
   case 16: new DispatchImpl16();
   case 17: new DispatchImpl17();
   case 18: new DispatchImpl18();
   case 19: new DispatchImpl19();
   case 20: new DispatchImpl20();
   case 21: new DispatchImpl21();
   case 22: new DispatchImpl22();
   case 23: new DispatchImpl23();
   case 24: new DispatchImpl24();
   case 25: new DispatchImpl25();
   case 26: new DispatchImpl26();
   case 27: new DispatchImpl27();
   case 28: new DispatchImpl28();
   case 29: new DispatchImpl29();
   case 30: new DispatchImpl30();
   case 31: new DispatchImpl31();
   default: throw "unknown receiver";
  };
 }
 public static function run(kind:Int):Int {
  var inherited=receiver(kind),base:DispatchReader=inherited,bound=base.read;
  var a=base.read(),b=bound(),c=inherited.read();
  if(a.number!=kind+2 || b.number!=kind+2 || c.number!=kind+2)return 1;
  if(a.owner.number!=40 || a.owner!=b.owner || b.owner!=c.owner || base.plain()!=7)return 2;
  var erased:Dynamic=bound,restored:Void->DispatchPacket=cast erased;
  var d=restored();if(d.number!=kind+2 || d.owner!=a.owner)return 3;
  var reflected:Void->DispatchPacket=cast Reflect.field(base,"read");
  var e=reflected();if(e.number!=kind+2 || e.owner!=a.owner)return 4;
  return 0;
 }
}
function main():Int {
 for(kind in 0...32){var result=DispatchCheck.run(kind);if(result!=0)return result;}
 return 42;
}
