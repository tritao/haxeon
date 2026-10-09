import haxe.crypto.Sha256;
import haxe.io.Bytes;

function main():Int {
	var expected = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
	var digest = Sha256.make(Bytes.ofString("abc"));
	if (digest.length != 32 || digest.get(0) != 0xba || digest.get(31) != 0xad)
		return 2;
	if (Sha256.encode("abc") != expected)
		return 1;
	if (Sha256.encode("") != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
		return 3;
	if (Sha256.encode("é") != "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c")
		return 4;
	if (Sha256.encode("The quick brown fox jumps over the lazy dog") != "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
		return 5;
	{
		var input = Bytes.alloc(0);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(1);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "e7cf46a078fed4fafd0b5e3aff144802b853f8ae459a4f0c14add3314b7cc3a6")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(55);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "2900465fcb533e05a158fd2b3be0e5e3b03740d83060aa3580e0d98a96bf2384")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(56);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "31454ff48ef36af2f08fd511bdc37d9d5855ac23e992e5ff5445cb6b7674a674")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(63);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "5f6401b96532c36de4e65beec0409b69b1d181864c8009b7a04f43e5d56350d1")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(64);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "94eb5de4943613fd048dc93393ab06877405faa39c11f53e9386083339833e7e")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(65);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "fc518669b6eb4b4dd91827ecacef86689c725bd5bab888fd3b26dbb196eec954")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(119);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "b0dc41b1a384e2f1203f0351b38fbeaafceef577ce1191d5bfc25da39f721eae")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(120);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "5df24dd802ac26132ce608dcb5f09841eef039ee0f152acf98d26d17fe4e88e6")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(127);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "0fe729ff19257bd6fec853acc2ea355f6b34b58e6c0f684c3e188fcdfcd9baae")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(128);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "0aedd4856f8eba0963627336ad5144a9a7dbe12498e6066f0165fc97d8ddee4c")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(129);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "4f1757ae4bffbae86d775b831765b75af154d52f7deaa46dd378051a2d3ad57f")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(255);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "3c835ac0bba7147eaa568a76183d465e72ac456df24b55e01d44dc87be05a971")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(256);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "3ef33734daae0e353f132ff5f3241d8f86ba81f851c0b9685149f079c16eb45b")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(1024);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "ffbad8f947474cfdd5b2bb22d7e0bf5ee8ba2b7af859d0c2bb28622db6a4be47")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	{
		var input = Bytes.alloc(1000000);
		for (i in 0...input.length)
			input.set(i, (i * 37 + 11) & 255);
		if (hex(Sha256.make(input)) != "047207f05c235c6490b408242a86a6f1d4c03d0e754902bd13efeb29f7f08a66")
			return 10;
		for (i in 0...input.length)
			if (input.get(i) != ((i * 37 + 11) & 255))
				return 11;
	}
	var parity = Bytes.alloc(4097);
	for (i in 0...parity.length)
		parity.set(i, (i * 19 + 7) & 255);
	if (hex(Sha256.make(parity)) != hex(Sha256.portableMake(parity)))
		return 13;
	var backing = Bytes.alloc(200);
	for (i in 0...backing.length)
		backing.set(i, (i * 37 + 11) & 255);
	if (hex(Sha256.make(Bytes.view(backing, 3, 129))) != "c3d99f5d1568687700c609edc2f4aba431b0fcb4eda97737964714890e167fe2")
		return 12;
	return 42;
}

function hex(bytes:Bytes):String {
	var digits = "0123456789abcdef", result = new StringBuf();
	for (i in 0...bytes.length) {
		var value = bytes.get(i);
		result.add(digits.charAt(value >>> 4));
		result.add(digits.charAt(value & 15));
	}
	return result.toString();
}
