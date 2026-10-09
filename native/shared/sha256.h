/* Shared SHA-256 compression kernel, FIPS 180-4. No globals, allocation, libc calls, or implicit Wasm stack.
 * The caller owns 416 bytes of aligned workspace. Round constants are immediates so linking needs no data section. */
#include <stdint.h>
#include <stddef.h>

static uint32_t realtime_sha256_rotate(uint32_t value, unsigned count) {
	return (value >> count) | (value << (32 - count));
}

static void realtime_sha256_block(uint32_t state[8], const unsigned char block[64], uint32_t words[64]) {
	for (unsigned i = 0; i < 16; ++i) {
		unsigned at = i * 4;
		words[i] = ((uint32_t)block[at] << 24) | ((uint32_t)block[at + 1] << 16)
			| ((uint32_t)block[at + 2] << 8) | (uint32_t)block[at + 3];
	}
	for (unsigned i = 16; i < 64; ++i) {
		uint32_t a = words[i - 15], b = words[i - 2];
		words[i] = words[i - 16] + (realtime_sha256_rotate(a, 7) ^ realtime_sha256_rotate(a, 18) ^ (a >> 3))
			+ words[i - 7] + (realtime_sha256_rotate(b, 17) ^ realtime_sha256_rotate(b, 19) ^ (b >> 10));
	}
	uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
	uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
#define SHA_ROUND(i, constant) do { \
	uint32_t first = h + (realtime_sha256_rotate(e, 6) ^ realtime_sha256_rotate(e, 11) ^ realtime_sha256_rotate(e, 25)) \
		+ ((e & f) ^ (~e & g)) + constant + words[i]; \
	uint32_t second = (realtime_sha256_rotate(a, 2) ^ realtime_sha256_rotate(a, 13) ^ realtime_sha256_rotate(a, 22)) \
		+ ((a & b) ^ (a & c) ^ (b & c)); \
	h = g; g = f; f = e; e = d + first; d = c; c = b; b = a; a = first + second; \
} while (0)
	SHA_ROUND(0, 0x428a2f98u);
	SHA_ROUND(1, 0x71374491u);
	SHA_ROUND(2, 0xb5c0fbcfu);
	SHA_ROUND(3, 0xe9b5dba5u);
	SHA_ROUND(4, 0x3956c25bu);
	SHA_ROUND(5, 0x59f111f1u);
	SHA_ROUND(6, 0x923f82a4u);
	SHA_ROUND(7, 0xab1c5ed5u);
	SHA_ROUND(8, 0xd807aa98u);
	SHA_ROUND(9, 0x12835b01u);
	SHA_ROUND(10, 0x243185beu);
	SHA_ROUND(11, 0x550c7dc3u);
	SHA_ROUND(12, 0x72be5d74u);
	SHA_ROUND(13, 0x80deb1feu);
	SHA_ROUND(14, 0x9bdc06a7u);
	SHA_ROUND(15, 0xc19bf174u);
	SHA_ROUND(16, 0xe49b69c1u);
	SHA_ROUND(17, 0xefbe4786u);
	SHA_ROUND(18, 0x0fc19dc6u);
	SHA_ROUND(19, 0x240ca1ccu);
	SHA_ROUND(20, 0x2de92c6fu);
	SHA_ROUND(21, 0x4a7484aau);
	SHA_ROUND(22, 0x5cb0a9dcu);
	SHA_ROUND(23, 0x76f988dau);
	SHA_ROUND(24, 0x983e5152u);
	SHA_ROUND(25, 0xa831c66du);
	SHA_ROUND(26, 0xb00327c8u);
	SHA_ROUND(27, 0xbf597fc7u);
	SHA_ROUND(28, 0xc6e00bf3u);
	SHA_ROUND(29, 0xd5a79147u);
	SHA_ROUND(30, 0x06ca6351u);
	SHA_ROUND(31, 0x14292967u);
	SHA_ROUND(32, 0x27b70a85u);
	SHA_ROUND(33, 0x2e1b2138u);
	SHA_ROUND(34, 0x4d2c6dfcu);
	SHA_ROUND(35, 0x53380d13u);
	SHA_ROUND(36, 0x650a7354u);
	SHA_ROUND(37, 0x766a0abbu);
	SHA_ROUND(38, 0x81c2c92eu);
	SHA_ROUND(39, 0x92722c85u);
	SHA_ROUND(40, 0xa2bfe8a1u);
	SHA_ROUND(41, 0xa81a664bu);
	SHA_ROUND(42, 0xc24b8b70u);
	SHA_ROUND(43, 0xc76c51a3u);
	SHA_ROUND(44, 0xd192e819u);
	SHA_ROUND(45, 0xd6990624u);
	SHA_ROUND(46, 0xf40e3585u);
	SHA_ROUND(47, 0x106aa070u);
	SHA_ROUND(48, 0x19a4c116u);
	SHA_ROUND(49, 0x1e376c08u);
	SHA_ROUND(50, 0x2748774cu);
	SHA_ROUND(51, 0x34b0bcb5u);
	SHA_ROUND(52, 0x391c0cb3u);
	SHA_ROUND(53, 0x4ed8aa4au);
	SHA_ROUND(54, 0x5b9cca4fu);
	SHA_ROUND(55, 0x682e6ff3u);
	SHA_ROUND(56, 0x748f82eeu);
	SHA_ROUND(57, 0x78a5636fu);
	SHA_ROUND(58, 0x84c87814u);
	SHA_ROUND(59, 0x8cc70208u);
	SHA_ROUND(60, 0x90befffau);
	SHA_ROUND(61, 0xa4506cebu);
	SHA_ROUND(62, 0xbef9a3f7u);
	SHA_ROUND(63, 0xc67178f2u);
#undef SHA_ROUND
	state[0] += a; state[1] += b; state[2] += c; state[3] += d;
	state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static void realtime_sha256_digest(const unsigned char *input, size_t length, unsigned char output[32], uint32_t scratch[104]) {
	uint32_t *state = scratch, *words = scratch + 8;
	state[0] = 0x6a09e667; state[1] = 0xbb67ae85; state[2] = 0x3c6ef372; state[3] = 0xa54ff53a;
	state[4] = 0x510e527f; state[5] = 0x9b05688c; state[6] = 0x1f83d9ab; state[7] = 0x5be0cd19;
	size_t offset = 0;
	while (length - offset >= 64) {
		realtime_sha256_block(state, input + offset, words);
		offset += 64;
	}
	unsigned char *tail = (unsigned char *)(scratch + 72);
	for (unsigned i = 0; i < 128; ++i) ((volatile unsigned char *)tail)[i] = 0;
	size_t remainder = length - offset;
	for (size_t i = 0; i < remainder; ++i) tail[i] = input[offset + i];
	tail[remainder] = 0x80;
	size_t padded = remainder < 56 ? 64 : 128;
	uint64_t bits = (uint64_t)length * 8;
	for (unsigned i = 0; i < 8; ++i) tail[padded - 1 - i] = (unsigned char)(bits >> (i * 8));
	realtime_sha256_block(state, tail, words);
	if (padded == 128) realtime_sha256_block(state, tail + 64, words);
	for (unsigned i = 0; i < 8; ++i)
		for (unsigned j = 0; j < 4; ++j) output[i * 4 + j] = (unsigned char)(state[i] >> (24 - j * 8));
}

