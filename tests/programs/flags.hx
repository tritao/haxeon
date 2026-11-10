enum abstract Access(Int) implements Flags {
    var None=0;
    var Read=1;
    var Write=2;
    var Execute=4;
    var High=1<<31;
    var ReadWrite=Read|Write;
}
struct Pair {
    public final code:Access;
    public final value:Int;
    public function new(code:Access,value:Int) {this.code=code;this.value=value;}
}
class Holder { public var code:Access; public var initial:Access=Access.empty(); public function new(code:Access) this.code=code; }
function read<T:Flags>(value:T):Int return value.rawValue();
class Probe {
    @:expose public static function perform(count:Int):Int {
        var total=0;
        for(index in 0...count) {
            var value=Access.fromRaw(index&7);
            var combined=(value|Access.Read).insert(Access.Write);
            if(!combined.contains(Access.ReadWrite) || combined.isSingle() || combined.isEmpty()) return -1;
            var result=combined.remove(Access.Write)&Access.Read;
            if(!result.isSingle() || !Access.empty().isEmpty()) return -2;
            total+=read(result);
        }
        return total;
    }
}
function main():Int {
    var before=Access.Read, after=before.insert(Access.Write);
    if(before!=Access.Read || after!=Access.ReadWrite) return 1;
    if(Access.fromRaw(5).rawValue()!=5 || !after.contains(Access.Read) || !after.contains(Access.empty()))return 2;
    if(after.toString()!="Access.ReadWrite" || Access.fromRaw(5).toString()!="Access[Read | Execute]")return 3;
    if(!Access.High.isSingle() || Access.fromRaw(-2147483648)!=Access.High)return 4;
    var caught=false;
    try { Access.fromRaw(8); }catch(error:Dynamic) {caught=true;}
    if(!caught) return 5;
    var holder=new Holder(Access.Read), pair=new Pair(Access.Write,40), values:Array<Access>=[Access.None,Access.Read];
    if(!holder.initial.isEmpty() || holder.code!=Access.Read || pair.code.rawValue()+pair.value!=42 || values[1]!=Access.Read)return 6;
    if(Probe.perform(32)!=32)return 7;
    return 42;
}
