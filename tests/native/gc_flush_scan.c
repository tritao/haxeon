/* The word-at-a-time free-run scan of a fixed-class page (vendor/hashlink/src/gc_flush_scan.h) must produce, run for run, the
   list the one-block-at-a-time loop of flush_free_list produced. The reference below is that loop, kept as it was. */
#include <stdio.h>
#include <stdlib.h>
#include "../../vendor/hashlink/src/gc_flush_scan.h"

#define MAX_RUNS 4096

typedef struct {
	int count;
	gc_fl runs[MAX_RUNS];
} run_list;

static void collect(void *context, int pos, int count) {
	run_list *list = (run_list*)context;
	if (list->count == MAX_RUNS) {
		fprintf(stderr, "FAIL: too many runs\n");
		exit(2);
	}
	list->runs[list->count].pos = (fl_cursor)pos;
	list->runs[list->count].count = (fl_cursor)count;
	list->count++;
}

/* flush_free_list's loop for a page without a size table, writing into an array instead of a gc_freelist. */
static void reference(const unsigned char *bmp, int first, int last, const gc_fl *old, int old_count, run_list *out) {
	int bid = first, next_old = 0;
	gc_fl *cur_pos = NULL;
	const gc_fl *reuse = next_old < old_count ? old + next_old++ : NULL;
	int next_bid = reuse ? (int)reuse->pos : -1;
	out->count = 0;
	while (bid < last) {
		if (bid == next_bid) {
			if (cur_pos && cur_pos->pos + cur_pos->count == (fl_cursor)bid) {
				cur_pos->count += reuse->count;
			} else {
				collect(out, (int)reuse->pos, (int)reuse->count);
				cur_pos = &out->runs[out->count - 1];
			}
			reuse = next_old < old_count ? old + next_old++ : NULL;
			bid = (int)(cur_pos->count + cur_pos->pos);
			next_bid = reuse ? (int)reuse->pos : -1;
			continue;
		}
		if ((bmp[bid >> 3] & (1 << (bid & 7))) == 0) {
			if (cur_pos && cur_pos->pos + cur_pos->count == (fl_cursor)bid)
				cur_pos->count += 1;
			else {
				collect(out, bid, 1);
				cur_pos = &out->runs[out->count - 1];
			}
		}
		bid += 1;
	}
}

static unsigned int state = 12345;
static unsigned int next_random(void) {
	state ^= state << 13;
	state ^= state >> 17;
	state ^= state << 5;
	return state;
}

/* A page's marks in one of several densities, so runs of 1, of 64 and of whole pages all occur. */
static void fill(unsigned char *bmp, int blocks, int pattern) {
	int bytes = (blocks + 7) / 8 + 8;
	for (int i = 0; i < bytes; i++) {
		unsigned int r = next_random();
		switch (pattern) {
		case 0: bmp[i] = 0; break;
		case 1: bmp[i] = 0xFF; break;
		case 2: bmp[i] = (unsigned char)r; break;
		case 3: bmp[i] = (r % 64 == 0) ? (unsigned char)(1 << (r >> 8 & 7)) : 0; break;
		case 4: bmp[i] = (r % 64 == 0) ? (unsigned char)~(1 << (r >> 8 & 7)) : 0xFF; break;
		case 5: bmp[i] = 0x55; break;
		case 6: bmp[i] = (i / 8) % 2 ? 0xFF : 0x00; break;
		default: bmp[i] = (r % 16 == 0) ? (unsigned char)r : 0; break;
		}
	}
}

/* Old free runs inside [first, last), in position order and not overlapping, some adjacent to each other, some over marked blocks. */
static int old_runs(gc_fl *old, int first, int last) {
	int count = 0, at = first;
	int density = (int)(next_random() % 4);
	while (at < last && count < 64) {
		unsigned int r = next_random();
		if (density == 0 && r % 3) { at += 1 + (int)(r >> 4) % 9; continue; }
		at += (int)(r >> 2) % (density == 3 ? 3 : 70);
		if (at >= last) break;
		int length = 1 + (int)(next_random() % (density == 1 ? 3 : 120));
		if (at + length > last) length = last - at;
		old[count].pos = (fl_cursor)at;
		old[count].count = (fl_cursor)length;
		count++;
		at += length;
		if (next_random() % 4 == 0) at += 0; /* adjacent to the next run */
	}
	return count;
}

int main(void) {
	static unsigned char bmp[1024 + 16];
	gc_fl old[128];
	run_list expected, actual;
	long cases = 0;
	/* The scan helper itself: every start, limit and wanted value against a bit-by-bit search. */
	for (int pattern = 0; pattern < 8; pattern++) {
		fill(bmp, 1024, pattern);
		for (int from = 0; from < 200; from += (from < 70 ? 1 : 7))
			for (int limit = from; limit <= 1024; limit += (limit < from + 140 ? 1 : 61))
				for (int want = 0; want < 2; want++) {
					int expect = limit;
					for (int b = from; b < limit; b++)
						if (((bmp[b >> 3] >> (b & 7)) & 1) == want) { expect = b; break; }
					if (gc_bitmap_next(bmp, from, limit, want) != expect) {
						fprintf(stderr, "FAIL: next bit %d from %d to %d pattern %d\n", want, from, limit, pattern);
						return 1;
					}
				}
	}
	/* The whole page, against the reference loop. */
	for (int round = 0; round < 40000; round++) {
		int blocks = 8 + (int)(next_random() % 1017);
		int first = (int)(next_random() % 40);
		if (first >= blocks) first = 0;
		int pattern = (int)(next_random() % 8);
		int count = (next_random() % 3) ? old_runs(old, first, blocks) : 0;
		fill(bmp, blocks, pattern);
		reference(bmp, first, blocks, old, count, &expected);
		actual.count = 0;
		gc_fixed_free_runs(bmp, first, blocks, old, count, collect, &actual);
		cases++;
		int same = actual.count == expected.count;
		for (int i = 0; same && i < actual.count; i++)
			same = actual.runs[i].pos == expected.runs[i].pos && actual.runs[i].count == expected.runs[i].count;
		if (!same) {
			fprintf(stderr, "FAIL: round %d blocks %d first %d pattern %d old runs %d: %d runs, expected %d\n", round, blocks, first, pattern, count, actual.count, expected.count);
			return 1;
		}
	}
	printf("PASS: free runs of fixed-class pages match the one-block-at-a-time scan (%ld pages)\n", cases);
	return 0;
}
