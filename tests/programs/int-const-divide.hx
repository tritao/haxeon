// Remainders and shifts by constants, including negative and extreme operands. The JIT replaces a divide by a constant
// with a multiply and shift and a shift count with an immediate; the checksum must not change.
function mix(hash:Int, value:Int):Int
	return hash * 31 + value;

function remainders(n:Int):Int {
	var h = 17;
	h = mix(h, n % 2);
	h = mix(h, n % 3);
	h = mix(h, n % 5);
	h = mix(h, n % 7);
	h = mix(h, n % 10);
	h = mix(h, n % 16);
	h = mix(h, n % 60);
	h = mix(h, n % 100);
	h = mix(h, n % 255);
	h = mix(h, n % 1000);
	h = mix(h, n % 4096);
	h = mix(h, n % 65537);
	h = mix(h, n % 139968);
	h = mix(h, n % 1000003);
	h = mix(h, n % 268435456);
	h = mix(h, n % 2147483647);
	h = mix(h, n % 1);
	h = mix(h, n % -1);
	return h;
}

function shifts(n:Int):Int {
	var h = 5;
	h = mix(h, n << 1);
	h = mix(h, n << 3);
	h = mix(h, n << 31);
	h = mix(h, n >> 1);
	h = mix(h, n >> 5);
	h = mix(h, n >> 31);
	h = mix(h, n >>> 1);
	h = mix(h, n >>> 7);
	h = mix(h, n >>> 31);
	h = mix(h, n << 0);
	return h;
}

function checksum():Int {
	var edge = [
		0,
		1,
		-1,
		2,
		-2,
		3,
		-3,
		7,
		-7,
		139967,
		-139967,
		139968,
		-139968,
		139969,
		2147483647,
		-2147483647,
		-2147483648,
		1073741824,
		-1073741824
	];
	var h = 1;
	for (n in edge) {
		h = mix(h, remainders(n));
		h = mix(h, shifts(n));
	}
	var n = 12345;
	for (i in 0...30000) {
		n = n * 1103515245 + 12345;
		h = mix(h, remainders(n));
		h = mix(h, shifts(n));
		h = mix(h, remainders(-n));
	}
	return h;
}

function main():Int {
	if (checksum() != -1588315278)
		return 1;
	return 42;
}
