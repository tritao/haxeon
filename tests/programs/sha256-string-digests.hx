import haxe.crypto.Sha256;
import haxe.io.Bytes;

// Sha256.encode is the SHA-256 of a string's UTF-8 bytes, also for one beyond ASCII (docs/reference/LANGUAGE_SUPPORT.md: stock
// Haxe pads such a string by its UTF-16 length and gives another digest).
function main():Int {
	var long = "", mixed = "";
	for (_ in 0...30)
		long += "é";
	for (_ in 0...50)
		mixed += "a";
	mixed += "\u{1F600}…";
	var cases = [
		"abc" => "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"café" => "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e",
		"中文" => "72726d8818f693066ceb69afa364218b692e62ea92b385782363780f47529c21",
		"\u{1F600}" => "f0443a342c5ef54783a111b51ba56c938e474c32324d90c3a60c9c8e3a37e2d9",
		"a\u{1F600}b" => "6fba5b2ea783ded096fc2444d540ffbdf49168df30993b155b7efb683313f110",
		"$string:)…:object String" => "58d63ec57d15af909244e1ab9ac50b065f54868c49a892350a8d74a8e372d9f5",
		long => "f96161c7582c75dfbae0062dd80f5447fad55546eea05fd785f982d194261aae",
		mixed => "1854e5901414242a55bb814cbecd0b4470d287046d8377ae6e2e4a47aabdb695"
	];
	for (text => expected in cases) {
		if (Sha256.encode(text) != expected)
			return 1;
		if (Sha256.make(Bytes.ofString(text)).toHex() != expected)
			return 2;
	}
	return 42;
}
