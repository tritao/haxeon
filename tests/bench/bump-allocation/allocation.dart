import "dart:io";
void main(List<String> args) { final n=int.parse(args[1]); switch(args[0]) {
case "16":
final ring=List<Node16?>.filled(256,null); double checksum=0;
for(int i=0;i<n;i++) { final o=Node16((i & 1023).toDouble()); ring[i & 255]=o; checksum+=o.f0; }
for(final o in ring) { if(o!=null) checksum+=o.f0; }
print(checksum); break;
case "24":
final ring=List<Node24?>.filled(256,null); double checksum=0;
for(int i=0;i<n;i++) { final o=Node24((i & 1023).toDouble()); ring[i & 255]=o; checksum+=o.f0; }
for(final o in ring) { if(o!=null) checksum+=o.f0; }
print(checksum); break;
case "40":
final ring=List<Node40?>.filled(256,null); double checksum=0;
for(int i=0;i<n;i++) { final o=Node40((i & 1023).toDouble()); ring[i & 255]=o; checksum+=o.f0; }
for(final o in ring) { if(o!=null) checksum+=o.f0; }
print(checksum); break;
default: throw ArgumentError("size");
}
}
class Node16 { double f0; Node16(double x): f0=x+0.0; }
class Node24 { double f0; double f1; Node24(double x): f0=x+0.0, f1=x+1.0; }
class Node40 { double f0; double f1; double f2; double f3; Node40(double x): f0=x+0.0, f1=x+1.0, f2=x+2.0, f3=x+3.0; }
