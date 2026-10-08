#include <hl.h>
#include <stdio.h>
#include <stdlib.h>

static int check(int condition, const char *message) {
    if (!condition) fprintf(stderr, "FAIL: %s\n", message);
    return condition;
}

int main(void) {
    int marker = 0, owner_a = 0, owner_b = 0;
    const int count = 32768;
    void **slots = calloc(count, sizeof(void*));
    int *order = malloc(count * sizeof(int));
    if (!slots || !order) return 2;
    hl_global_init();
    hl_register_thread(&marker);
    /* Force repeated index growth and many hash collisions. Each root keeps an
       independently allocated object alive, even though the slots are not GC memory. */
    for (int i = 0; i < count; i++) {
        slots[i] = hl_gc_alloc_gen(NULL, 16, MEM_KIND_NOPTR | MEM_ZERO);
        ((int*)slots[i])[0] = i;
        hl_add_root_owner(&slots[i], &owner_a);
        order[i] = i;
    }
    if (!check(hl_gc_owner_root_count(&owner_a) == count, "root ownership after growth")) return 1;
    hl_gc_major();
    for (int i = 0; i < count; i++)
        if (!check(((int*)slots[i])[0] == i, "registered root survives GC")) return 1;
    /* Duplicate registration removes the highest array index, as before. */
    hl_add_root_owner(&slots[7], &owner_b);
    hl_add_root_owner(&slots[7], &owner_a);
    hl_remove_root(&slots[7]);
    if (!check(hl_gc_owner_root_count(&owner_a) == count && hl_gc_owner_root_count(&owner_b) == 1,
               "duplicate removal preserves highest-index ownership")) return 1;
    hl_remove_root(&slots[7]);
    if (!check(hl_gc_owner_root_count(&owner_b) == 0, "duplicate owner released independently")) return 1;
    /* Deterministic shuffled removal exercises compaction into different buckets. */
    unsigned int seed = 17;
    for (int i = count - 1; i > 0; i--) {
        seed = seed * 1664525u + 1013904223u;
        int j = seed % (i + 1), swap = order[i]; order[i] = order[j]; order[j] = swap;
    }
    for (int i = 0; i < count; i++) {
        hl_remove_root(&slots[order[i]]);
        if ((i & 1023) == 0) hl_gc_major();
    }
    hl_remove_root(&slots[0]); /* Unknown roots are still harmless. */
    if (!check(hl_gc_owner_root_count(&owner_a) == 0, "all shuffled roots removed")) return 1;
    /* Reuse the index after the removals, including a duplicated root moved by compaction. */
    hl_add_root_owner(&slots[1], &owner_a);
    hl_add_root_owner(&slots[2], &owner_a);
    hl_add_root_owner(&slots[1], &owner_b);
    hl_remove_root(&slots[2]);
    hl_remove_root(&slots[1]);
    if (!check(hl_gc_owner_root_count(&owner_b) == 0 && hl_gc_owner_root_count(&owner_a) == 1,
               "compacted duplicate is found")) return 1;
    hl_remove_root(&slots[1]);
    free(order); free(slots);
    hl_global_free();
    puts("PASS: GC root index growth, liveness, ownership, duplicates and shuffled removal");
    return 0;
}
