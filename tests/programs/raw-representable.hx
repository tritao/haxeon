enum abstract OpenBits(Int) from Int to Int { var One=1; var Two=2; }
enum abstract Code(Int) implements RawRepresentable {
    var Zero = 0;
    var Red = 4;
    var Blue = 7;
    var Alias = Red;
    var High = 0x7fffffff;
}
enum abstract Mime(String) implements RawRepresentable {
    var Json = "application/json";
    var Text = "text/plain";
}
struct Pair {
    public final code:Code;
    public final value:Int;
    public function new(code:Code, value:Int) { this.code=code; this.value=value; }
}
class Holder {
    public var code:Code;
    public function new(code:Code) this.code=code;
}
function read<T:RawRepresentable>(value:T):Int return value.rawValue();
class Probe {
    @:expose public static function raw(count:Int):Int {
        var total=0;
        for (index in 0...count) total+=read(Code.Red)+Code.Blue.rawValue();
        return total;
    }
}
function main():Int {
    var bits:OpenBits=OpenBits.One | OpenBits.Two;
    if(bits!=3) return 10;
    var code:Code=Code.Red;
    if (code!=Code.Alias || code.rawValue()!=4) return 1;
    var values:Array<Code>=[Code.Red, Code.Blue];
    if (values[1].rawValue()!=7) return 2;
    var holder=new Holder(Code.Blue);
    if (holder.code!=Code.Blue) return 3;
    var pair=new Pair(Code.Red,38);
    if (pair.code.rawValue()+pair.value!=42) return 4;
    var zero=Code.fromRaw(0);
    if(zero==null || zero.rawValue()!=0) return 11;
    var known=Code.fromRaw(7);
    if (known==null || known!=Code.Blue || known.rawValue()!=7) return 5;
    if (Code.fromRaw(99)!=null || Code.fromRaw(-1)!=null) return 6;
    var text=Mime.fromRaw("text/plain");
    if (text==null || text!=Mime.Text || text.rawValue()!="text/plain") return 7;
    if (Mime.fromRaw("unknown")!=null) return 8;
    if (read(Code.Red)!=4 || Probe.raw(2)!=22) return 9;
    return 42;
}
