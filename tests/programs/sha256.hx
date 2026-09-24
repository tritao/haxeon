import haxe.crypto.Sha256;
import haxe.io.Bytes;

function main():Int {
  var expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
  var digest = Sha256.make(Bytes.ofString("abc"));
  if (digest.length != 32 || digest.get(0) != 0xba || digest.get(31) != 0xad) return 2;
  if (Sha256.encode("abc") != expected) return 1;
  if (Sha256.encode("") != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") return 3;
  if (Sha256.encode("é") != "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c") return 4;
  if (Sha256.encode("The quick brown fox jumps over the lazy dog")
    != "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592") return 5;
  return 42;
}
