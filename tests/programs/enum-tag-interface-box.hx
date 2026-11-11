enum Kind implements Equatable { First; Second; }
struct Payload implements Equatable {
 public final kind:Kind;
 public final number:Float;
 public function new(kind:Kind,number:Float) { this.kind=kind;this.number=number; }
}
function main():Int {
 var boxed:Equatable=new Payload(Kind.Second,41.0);
 var recovered:Payload=cast boxed;
 if(recovered.kind!=Kind.Second || recovered.number!=41.0)return 1;
 var missing:Equatable=new Payload(null,0.0);
 var recoveredMissing:Payload=cast missing;
 return recoveredMissing.kind==null && recoveredMissing.number==0.0 ? 42 : 2;
}
