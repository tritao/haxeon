// Tallies the live blocks of a HashLink memory dump (HMD1) by the type pointer in their first word.
// usage: hl-heap-tally <dump> > tally.tsv   (columns: kind, type-index, type-pointer, blocks, bytes); build: cc -O2 -o hl-heap-tally hl-heap-tally.c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

typedef struct { uint64_t key; uint64_t blocks; uint64_t bytes; int index; int kind; } entry;
static entry *table; static size_t cap;
static uint64_t hash64(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; x *= 0xc4ceb9fe1a85ec53ULL; x ^= x >> 33; return x; }
static entry *slot(uint64_t key) {
	size_t i = hash64(key) & (cap - 1);
	while (table[i].key != 0 && table[i].key != key) i = (i + 1) & (cap - 1);
	table[i].key = key; return &table[i];
}
static void must(size_t got, size_t want) { if (got != want) { fprintf(stderr, "short read\n"); exit(2); } }
static int32_t ri(FILE *f) { int32_t v; must(fread(&v, 1, 4, f), 4); return v; }
static uint64_t rp(FILE *f) { uint64_t v; must(fread(&v, 1, 8, f), 8); return v; }

int main(int argc, char **argv) {
	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror("open"); return 1; }
	setvbuf(f, NULL, _IOFBF, 1 << 22);
	char magic[4]; must(fread(magic, 1, 4, f), 4);
	if (memcmp(magic, "HMD1", 4)) { fprintf(stderr, "not a dump\n"); return 1; }
	int32_t flags = ri(f); int32_t privateData = ri(f); int32_t markStack = ri(f);
	int32_t pages = ri(f);
	if (!(flags & 1)) { fprintf(stderr, "32-bit dump\n"); return 1; }
	long start = ftell(f);
	// pass 1: skip to the type table
	for (int p = 0; p < pages; p++) {
		rp(f); int32_t kind = ri(f), size = ri(f); ri(f);
		if (kind & 2) { for (;;) { uint64_t b = rp(f); if (!b) break; int32_t s = ri(f); if (s >= 8) rp(f); } }
		else { for (;;) { uint64_t b = rp(f); if (!b) break; ri(f); } fseek(f, size, SEEK_CUR); }
	}
	int32_t roots = ri(f); fseek(f, (long)roots * 8, SEEK_CUR);
	int32_t threads = ri(f);
	for (int t = 0; t < threads; t++) { rp(f); int32_t n = ri(f); fseek(f, (long)n * 8, SEEK_CUR); }
	cap = 1 << 22; table = calloc(cap, sizeof(entry));
	for (;;) { int32_t k = ri(f); if (k < 0) break; slot(rp(f))->kind = k + 1000; }   // base types
	int32_t ntypes = ri(f);
	for (int i = 0; i < ntypes; i++) { entry *e = slot(rp(f)); e->index = i; e->kind = 1; }
	int32_t fcount = ri(f);
	for (int i = 0; i < fcount; i++) { entry *e = slot(rp(f)); e->index = -1; e->kind = 2; }
	// pass 2: tally
	fseek(f, start, SEEK_SET);
	uint64_t scanBlocks = 0, scanBytes = 0, rawBlocks = 0, rawBytes = 0, ptrfreeBlocks = 0, ptrfreeBytes = 0, unknownBlocks = 0, unknownBytes = 0;
	uint64_t pageBytes[4] = {0,0,0,0}, pageCount[4] = {0,0,0,0}, liveBytes[4] = {0,0,0,0};
	char *data = malloc(1 << 26); size_t dataCap = 1 << 26;
	typedef struct { uint64_t b; int32_t s; } blk;
	blk *blocks = malloc(sizeof(blk) * (1 << 20)); size_t blocksCap = 1 << 20;
	for (int p = 0; p < pages; p++) {
		uint64_t base = rp(f); int32_t kind = ri(f), size = ri(f); ri(f);
		if (kind >= 0 && kind < 4) { pageBytes[kind] += size; pageCount[kind]++; }
		if (kind & 2) {
			for (;;) {
				uint64_t b = rp(f); if (!b) break; int32_t s = ri(f); uint64_t t = 0;
				if (kind >= 0 && kind < 4) liveBytes[kind] += s;
				if (s >= 8) t = rp(f);
				entry *e = t ? slot(t) : NULL;
				if (e && e->kind) { e->blocks++; e->bytes += s; }
				else { ptrfreeBlocks++; ptrfreeBytes += s; }
			}
		} else {
			size_t n = 0;
			for (;;) {
				uint64_t b = rp(f); if (!b) break; int32_t s = ri(f);
				if (kind >= 0 && kind < 4) liveBytes[kind] += s;
				if (n == blocksCap) { blocksCap *= 2; blocks = realloc(blocks, sizeof(blk) * blocksCap); }
				blocks[n].b = b; blocks[n].s = s; n++;
			}
			if ((size_t)size > dataCap) { dataCap = size; data = realloc(data, dataCap); }
			must(fread(data, 1, size, f), size);
			for (size_t i = 0; i < n; i++) {
				uint64_t off = blocks[i].b - base; int32_t s = blocks[i].s; uint64_t t = 0;
				if (s >= 8 && off + 8 <= (uint64_t)size) memcpy(&t, data + off, 8);
				entry *e = t ? slot(t) : NULL;
				if (e && e->kind) { e->blocks++; e->bytes += s; }
				else if (kind == 1) { rawBlocks++; rawBytes += s; }
				else { unknownBlocks++; unknownBytes += s; }
			}
		}
	}
	printf("# pages %d ntypes %d fcount %d private_data %d mark_stack %d\n", pages, ntypes, fcount, privateData, markStack);
	const char *kn[4] = {"dynamic(scan)","raw","noptr","finalizer"};
	for (int k = 0; k < 4; k++) printf("# page-kind %s pages %llu page-bytes %llu live-block-bytes %llu\n", kn[k], (unsigned long long)pageCount[k], (unsigned long long)pageBytes[k], (unsigned long long)liveBytes[k]);
	printf("other\tpointer-free-or-untyped\t0\t%llu\t%llu\n", (unsigned long long)ptrfreeBlocks, (unsigned long long)ptrfreeBytes);
	printf("other\traw-blocks\t0\t%llu\t%llu\n", (unsigned long long)rawBlocks, (unsigned long long)rawBytes);
	printf("other\tscan-blocks-without-type\t0\t%llu\t%llu\n", (unsigned long long)unknownBlocks, (unsigned long long)unknownBytes);
	for (size_t i = 0; i < cap; i++) if (table[i].key && table[i].blocks)
		printf("%d\t%d\t%llu\t%llu\t%llu\n", table[i].kind, table[i].index, (unsigned long long)table[i].key, (unsigned long long)table[i].blocks, (unsigned long long)table[i].bytes);
	return 0;
}
