import haxeon.editor.TextDocument;
import haxeon.editor.TextOffsetMap;

class DocCheck {
 static function check(ok:Bool, label:String):Void if (!ok) throw label;
 static function validate(doc:TextDocument, expected:String, step:Int):Void {
  var map=new TextOffsetMap(expected);
  check(doc.text==expected,"text at "+step);
  check(doc.codepointCount==map.codepointCount,"code points at "+step);
  check(doc.utf8ByteLength==map.utf8ByteLength,"UTF-8 length at "+step);
  check(doc.utf16Length==map.utf16Length,"UTF-16 length at "+step);
  check(doc.paragraphCount()==map.paragraphCount(),"paragraph count at "+step);
  for (i in 0...doc.paragraphCount()) {
   var a=doc.paragraphRangeAtIndex(i); var b=map.paragraphRangeAtIndex(i);
   check(a.start==b.start&&a.end==b.end,"paragraph "+i+" at "+step);
  }
  var position=0;
  while (position<=doc.codepointCount) {
   var u8=doc.utf8OffsetForCodepoint(position);
   var u16=doc.utf16OffsetForCodepoint(position);
   check(u8==map.utf8OffsetForCodepoint(position)&&u16==map.utf16OffsetForCodepoint(position),"forward coordinate at "+step+":"+position);
   check(doc.codepointOffsetForUtf8(u8)==position&&doc.codepointOffsetForUtf16(u16)==position,"inverse coordinate at "+step+":"+position);
   check(doc.paragraphIndexAtOffset(position)==map.paragraphIndexAtOffset(position),"paragraph lookup at "+step+":"+position);
   position+=137;
  }
  check(doc.sliceCodepoints(0,doc.codepointCount)==expected,"full slice at "+step);
 }
 static function asciiGraphemes():Void {
  // HashLink text strings exclude NUL; exercise every representable ASCII pair.
  for (previous in 1...128) for (current in 1...128) {
   var map=new TextOffsetMap(String.fromCharCode(previous)+String.fromCharCode(current));
   check(map.isGraphemeBoundary(1)==(previous!=13||current!=10), "ASCII grapheme pair "+previous+":"+current);
  }
  var map=new TextOffsetMap("a\u0301b");
  check(!map.isGraphemeBoundary(1)&&map.isGraphemeBoundary(2),"ASCII next to combining mark");
  map=new TextOffsetMap("a\rX");
  map.replaceCodepointsIncremental(2,3,"\n");
  check(!map.isGraphemeBoundary(2),"edited CR/LF grapheme");
 }
 static function main():Void {
  asciiGraphemes();
  var content=new StringBuf();
  for (i in 0...260) content.add(StringTools.lpad(Std.string(i),"0",4)+" Café e\u0301 🙂 🧑‍💻 漢字 שלום\n");
  var expected=content.toString(); var doc=new TextDocument(expected);
  validate(doc,expected,0);
  for (step in 1...81) {
   var map=new TextOffsetMap(expected);
   var start=(step*7919)%(doc.codepointCount+1);
   var end=Std.int(Math.min(doc.codepointCount,start+step%5));
   var insert=switch(step%5) {case 0:"\n";case 1:"🧑‍💻";case 2:"e\u0301";case 3:"";case _:"漢🙂";};
   var next=map.replaceCodepoints(start,end,insert);
   doc.replace(start,end,insert);
   expected=next;
   validate(doc,expected,step);
  }
  var longParagraph=new StringBuf();
  for (_ in 0...1800) longParagraph.add("Cafe\u0301 🧑‍💻 漢字 שלום ");
  expected=longParagraph.toString();
  doc=new TextDocument(expected);
  validate(doc,expected,100);
  for (step in 1...41) {
   var map=new TextOffsetMap(expected);
   var start=(step*2053)%doc.codepointCount;
   var end=Std.int(Math.min(doc.codepointCount,start+step%4));
   var insert=switch(step%4) {case 0:"\n";case 1:"🧑‍💻";case 2:"e\u0301";case _:"漢🙂";};
   expected=map.replaceCodepoints(start,end,insert);
   doc.replace(start,end,insert);
   validate(doc,expected,100+step);
  }
  Sys.println("PASS Unicode document coordinates, 120 edits, and long-paragraph segment seams");
 }
}
