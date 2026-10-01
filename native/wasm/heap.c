// Allocation and sweeping for Haxeon's wasm32 (linear-memory) backend.
//
// Haxeon links this module into every wasm32 output (docs/WASM_LINEAR_RUNTIME.md). It owns the heap's free
// lists; the guest marks live blocks and then calls haxeon_heap_sweep. The module has no data, globals or stack
// of its own: all state is the hx_heap the guest reserves and passes in, laid out as WasmLayout.HEAP_STATE_*.
//
// Every heap block starts with a 16-byte header (WasmLayout.GC_BLOCK_*): its size including the header, flags
// (magic, allocated, marked, scan references), the owner the collector traces from, and a link that chains free
// blocks. Free blocks below SMALL_LIMIT sit on a list for their exact size, so a matching request pops one; larger
// ones sit on one list that requests take from first fit, carving from the end so the free block stays in place.

#include <stdint.h>

#define HEADER_SIZE 16u
#define SIZE_OFFSET 0
#define FLAGS_OFFSET 4
#define OWNER_OFFSET 8
#define LINK_OFFSET 12
#define BLOCK_MAGIC 0x48470000u
#define BLOCK_MAGIC_MASK 0xffff0000u
#define BLOCK_ALLOCATED 1u
#define BLOCK_MARKED 2u
#define BLOCK_SCAN_REFERENCES 4u
#define MIN_ALLOCATION_BUDGET 262144
#define SMALL_LIMIT 1024u
#define CLASS_COUNT (SMALL_LIMIT / 8u)
#define FLAG_STRESS 1u
#define FLAG_STATS 2u

typedef struct {
	uint32_t heap_start;
	uint32_t heap_top;
	int32_t budget;
	uint32_t live_bytes;
	uint32_t large_head;
	uint32_t flags;
	uint32_t allocation_count;
	uint32_t allocation_bytes;
	uint32_t largest_allocation;
	uint32_t collection_count;
	uint32_t classes[CLASS_COUNT];
} hx_heap;

// Marks from the guest's roots and then calls haxeon_heap_sweep.
__attribute__((import_module("haxeon_guest"), import_name("collect"))) extern void guest_collect(void);

#define WORD(address, offset) (*(uint32_t *)(uintptr_t)((address) + (offset)))

static uint32_t memory_bytes(void) {
	return (uint32_t)__builtin_wasm_memory_size(0) * 65536u;
}

static void push_free(hx_heap *heap, uint32_t block, uint32_t size) {
	uint32_t *head = size < SMALL_LIMIT ? &heap->classes[size >> 3] : &heap->large_head;
	WORD(block, SIZE_OFFSET) = size;
	WORD(block, FLAGS_OFFSET) = BLOCK_MAGIC;
	WORD(block, OWNER_OFFSET) = 0;
	WORD(block, LINK_OFFSET) = *head;
	*head = block;
}

// Unlinks and returns a free block of at least `size` bytes, storing its size; 0 when none fits.
static uint32_t take_free(hx_heap *heap, uint32_t size, uint32_t *taken) {
	if (size < SMALL_LIMIT) {
		uint32_t *head = &heap->classes[size >> 3];
		uint32_t block = *head;
		if (block != 0) {
			*head = WORD(block, LINK_OFFSET);
			*taken = size;
			return block;
		}
	}
	uint32_t previous = 0;
	for (uint32_t block = heap->large_head; block != 0; block = WORD(block, LINK_OFFSET)) {
		uint32_t available = WORD(block, SIZE_OFFSET);
		if (available >= size) {
			uint32_t remainder = available - size, next = WORD(block, LINK_OFFSET);
			// A block that will no longer be large leaves this list.
			if (remainder < SMALL_LIMIT) {
				if (previous == 0)
					heap->large_head = next;
				else
					WORD(previous, LINK_OFFSET) = next;
			}
			if (remainder < HEADER_SIZE) {
				*taken = available;
				return block;
			}
			// Carve the tail; a remainder that is no longer large moves to its exact-size list.
			WORD(block, SIZE_OFFSET) = remainder;
			if (remainder < SMALL_LIMIT)
				push_free(heap, block, remainder);
			*taken = size;
			return block + remainder;
		}
		previous = block;
	}
	return 0;
}

// The next collection comes after allocating as many bytes as the last one kept, so the heap settles near twice
// its live size.
static void replenish_budget(hx_heap *heap, uint32_t size) {
	int32_t next = (int32_t)heap->live_bytes;
	if (next < MIN_ALLOCATION_BUDGET)
		next = MIN_ALLOCATION_BUDGET;
	heap->budget = next - (int32_t)size;
}

static void collect(hx_heap *heap, uint32_t size) {
	guest_collect();
	if ((heap->flags & FLAG_STRESS) == 0)
		replenish_budget(heap, size);
}

/** Returns a zeroed payload of at least `requested` bytes. */
__attribute__((export_name("haxeon_heap_alloc"))) uint32_t haxeon_heap_alloc(hx_heap *heap, uint32_t requested) {
	uint32_t payload = (requested + 7u) & ~7u, size = payload + HEADER_SIZE, block_size = size;
	if (heap->flags & FLAG_STATS) {
		heap->allocation_count++;
		heap->allocation_bytes += payload;
		if (heap->largest_allocation < payload)
			heap->largest_allocation = payload;
	}
	int collected = 0;
	if (heap->flags & FLAG_STRESS) {
		guest_collect();
		collected = 1;
	} else if (heap->budget < (int32_t)size) {
		collect(heap, size);
		collected = 1;
	} else
		heap->budget -= (int32_t)size;
	uint32_t block = take_free(heap, size, &block_size);
	// Collection on memory pressure is mandatory even before the budget runs out.
	if (block == 0 && !collected && memory_bytes() < heap->heap_top + size) {
		collect(heap, size);
		block = take_free(heap, size, &block_size);
	}
	if (block != 0)
		// Reused blocks are cleared for Haxe's zero defaults; grown pages are already zero.
		__builtin_memset((void *)(uintptr_t)block, 0, block_size);
	else {
		block = heap->heap_top;
		block_size = size;
		uint32_t end = block + size;
		if (memory_bytes() < end && __builtin_wasm_memory_grow(0, (end + 65535u) / 65536u - __builtin_wasm_memory_size(0)) == (__SIZE_TYPE__)-1)
			__builtin_trap();
		heap->heap_top = end;
	}
	WORD(block, SIZE_OFFSET) = block_size;
	WORD(block, FLAGS_OFFSET) = BLOCK_MAGIC | BLOCK_ALLOCATED | BLOCK_SCAN_REFERENCES;
	WORD(block, OWNER_OFFSET) = block + HEADER_SIZE;
	WORD(block, LINK_OFFSET) = 0;
	return block + HEADER_SIZE;
}

/**
 * Frees every allocated block the guest did not mark, clears the marks, and rebuilds the free lists from runs of
 * adjacent free blocks. Traps on a malformed block, which means the heap was corrupted.
 */
__attribute__((export_name("haxeon_heap_sweep"))) void haxeon_heap_sweep(hx_heap *heap) {
	for (uint32_t index = 0; index < CLASS_COUNT; index++)
		heap->classes[index] = 0;
	heap->large_head = 0;
	heap->collection_count++;
	uint32_t live = 0, run_start = 0, run_size = 0;
	for (uint32_t block = heap->heap_start; block < heap->heap_top;) {
		uint32_t size = WORD(block, SIZE_OFFSET), flags = WORD(block, FLAGS_OFFSET);
		if (size < HEADER_SIZE || (size & 7u) != 0 || size > heap->heap_top - block || (flags & BLOCK_MAGIC_MASK) != BLOCK_MAGIC)
			__builtin_trap();
		if ((flags & BLOCK_ALLOCATED) && (flags & BLOCK_MARKED)) {
			live += size;
			if (run_size != 0)
				push_free(heap, run_start, run_size);
			run_size = 0;
			WORD(block, FLAGS_OFFSET) = flags & ~BLOCK_MARKED;
		} else {
			if (run_size == 0)
				run_start = block;
			run_size += size;
		}
		block += size;
	}
	if (run_size != 0)
		push_free(heap, run_start, run_size);
	heap->live_bytes = live;
}
