import haxe.Json;

function main():Int {
  var parsed:Dynamic = Json.parse(' {"é水":"🙂", "escaped":"a\\nb\\t\\\"c", "unicode":"\\u00e9\\u6c34", "pair":"\\ud83d\\ude42", "n":-1.25e-3} ');
  if (Reflect.field(parsed, "é水") != "🙂") return 1;
  if (Reflect.field(parsed, "escaped") != "a\nb\t\"c") return 2;
  if (Reflect.field(parsed, "unicode") != "é水") return 3;
  if (Reflect.field(parsed, "pair") != "🙂") return 4;
  var number:Float = Reflect.field(parsed, "n");
  if (Math.abs(number + 0.00125) > 1e-12) return 5;
  for (invalid in ['"\\ud800"', '"\\udc00"', '"\\ud800\\u0041"', '"\\x"', '"line\nbreak"', '[1,]', '{"x":}', '01', '1.', '1e+', 'true false']) {
    var rejected = false;
    try Json.parse(invalid) catch (_:Dynamic) rejected = true;
    if (!rejected) return 6;
  }
  var buffer = new StringBuf();
  if (buffer.toString() != "") return 8;
  buffer.add("é水🙂"); buffer.addSub("ab\nc", 1, 2); buffer.addChar(65);
  if (buffer.toString() != "é水🙂b\nA" || buffer.toString() != "é水🙂b\nA") return 9;
  buffer.add("tail");
  if (buffer.toString() != "é水🙂b\nAtail") return 10;
  var large = new StringBuf();
  large.add("[");
  for (i in 0...10000) { if (i > 0) large.add(","); large.add('"é水🙂"'); }
  large.add("]");
  var values:Array<Dynamic> = cast Json.parse(large.toString());
  return values.length == 10000 && values[9999] == "é水🙂" ? 42 : 7;
}
