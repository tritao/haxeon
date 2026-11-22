using System;
class Program { static void Main(string[] args) { int n=int.Parse(args[1]); switch(args[0]) {
case "16": {
var ring=new Node16[256]; double checksum=0;
for(int i=0;i<n;i++) { var o=new Node16(i & 1023); ring[i & 255]=o; checksum+=o.f0; }
foreach(var o in ring) if(o!=null) checksum+=o.f0;
Console.WriteLine(checksum); break; }
case "24": {
var ring=new Node24[256]; double checksum=0;
for(int i=0;i<n;i++) { var o=new Node24(i & 1023); ring[i & 255]=o; checksum+=o.f0; }
foreach(var o in ring) if(o!=null) checksum+=o.f0;
Console.WriteLine(checksum); break; }
case "40": {
var ring=new Node40[256]; double checksum=0;
for(int i=0;i<n;i++) { var o=new Node40(i & 1023); ring[i & 255]=o; checksum+=o.f0; }
foreach(var o in ring) if(o!=null) checksum+=o.f0;
Console.WriteLine(checksum); break; }
default: throw new Exception("size");
}
}
}
class Node16 { public double f0; public Node16(double x) { f0=x+0.0; } }
class Node24 { public double f0; public double f1; public Node24(double x) { f0=x+0.0; f1=x+1.0; } }
class Node40 { public double f0; public double f1; public double f2; public double f3; public Node40(double x) { f0=x+0.0; f1=x+1.0; f2=x+2.0; f3=x+3.0; } }
