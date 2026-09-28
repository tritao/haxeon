package haxe.crypto;

import haxe.io.Bytes;

/** Standard Base64 (RFC 4648) encoding with optional `=` padding. */
class Base64 {
  public static inline var CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

  public static function encode(bytes:Bytes, complement:Bool = true):String {
    var output = new StringBuf(), length = bytes.length, index = 0;
    while (index + 2 < length) {
      var value = (bytes.get(index) << 16) | (bytes.get(index + 1) << 8) | bytes.get(index + 2);
      output.addChar(CHARS.charCodeAt((value >> 18) & 63));
      output.addChar(CHARS.charCodeAt((value >> 12) & 63));
      output.addChar(CHARS.charCodeAt((value >> 6) & 63));
      output.addChar(CHARS.charCodeAt(value & 63));
      index += 3;
    }
    var remaining = length - index;
    if (remaining > 0) {
      var value = bytes.get(index) << 16;
      if (remaining == 2)
        value |= bytes.get(index + 1) << 8;
      output.addChar(CHARS.charCodeAt((value >> 18) & 63));
      output.addChar(CHARS.charCodeAt((value >> 12) & 63));
      if (remaining == 2)
        output.addChar(CHARS.charCodeAt((value >> 6) & 63));
      if (complement)
        output.add(remaining == 1 ? "==" : "=");
    }
    return output.toString();
  }

  public static function decode(text:String, complement:Bool = true):Bytes {
    var length = text.length;
    if (complement)
      while (length > 0 && text.charCodeAt(length - 1) == "=".code)
        length--;
    var output = Bytes.alloc(Std.int(length * 6 / 8)), accumulator = 0, bits = 0, position = 0;
    for (index in 0...length) {
      var digit = CHARS.indexOf(text.charAt(index));
      if (digit < 0)
        throw 'Invalid Base64 character at $index';
      accumulator = (accumulator << 6) | digit;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        output.set(position++, (accumulator >> bits) & 0xFF);
      }
    }
    return output;
  }
}
