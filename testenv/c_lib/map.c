#include "ds.h"
#include "iter.h"
#include "stack.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* Internal: FNV-1a over the key, folded into the bucket range. */
static unsigned long hash(const char *key) {
    unsigned long h = 1469598103934665603UL;
    while (*key != '\0') {
        h ^= (unsigned char)(*key);
        h *= 1099511628211UL;
        key += 1;
    }
    return h % DS_MAP_BUCKETS;
}

/* Internal: locate the entry for k within bucket b, or NULL. Shared by
 * map_put and map_get so the chain walk lives in one place. */
static Entry *bucket_find(Map *m, unsigned long b, const char *k) {
    Entry *e = m->buckets[b];
    while (e != NULL) {
        if (strcmp(e->key, k) == 0) {
            return e;
        }
        e = e->next;
    }
    return NULL;
}

/* Allocate an empty map with all buckets cleared. */
Map *map_new(void) {
    Map *m = calloc(1, sizeof(Map));
    return m;
}

/* Insert or overwrite k -> v. Returns DS_OK, or DS_ERR_OOM on allocation
 * failure. Rejects keys longer than DS_MAX_KEY_LEN. */
int map_put(Map *m, const char *k, int v) {
    if (strlen(k) > DS_MAX_KEY_LEN) {
        return DS_ERR_RANGE;
    }
    unsigned long b = hash(k);
    Entry *e = bucket_find(m, b, k);
    if (e != NULL) {
        e->value = v;
        return DS_OK;
    }
    e = malloc(sizeof(Entry));
    if (e == NULL) {
        return DS_ERR_OOM;
    }
    e->key = strdup(k);
    e->value = v;
    e->next = m->buckets[b];
    m->buckets[b] = e;
    m->count += 1;
    return DS_OK;
}

/* Look up k, returning its value or -1 when absent. */
int map_get(Map *m, const char *k) {
    unsigned long b = hash(k);
    Entry *e = bucket_find(m, b, k);
    if (e != NULL) {
        return e->value;
    }
    return -1;
}

/* Number of key/value pairs stored in the map. */
size_t map_size(const Map *m) {
    return m->count;
}

/* Genuinely dead: never referenced anywhere in the library. Kept to exercise
 * dead-code detection. Iterates via DS_ARRAY_LEN over the bucket array. */
static void debug_dump(Map *m) {
    for (size_t i = 0; i < DS_ARRAY_LEN(m->buckets); i += 1) {
        Entry *e = m->buckets[i];
        while (e != NULL) {
            printf("[%zu] %s=%d\n", i, e->key, e->value);
            e = e->next;
        }
    }
}

/* ---- Callbacks passed into the iter.c higher-order functions ------------ */
/* Double a value (an IntTransform). Referenced only via a function pointer. */
static int times_two(int x) {
    return x * 2;
}

/* Accept strictly-positive values (an IntPredicate). */
static int is_positive(int x) {
    return x > 0;
}

/* Sum accumulator (an IntReducer). */
static long add_up(long acc, int x) {
    return acc + x;
}

/* Print one entry (a MapVisitor); never stops early. */
static int print_entry(const char *key, int value, void *ctx) {
    DS_UNUSED(ctx);
    printf("%s -> %d\n", key, value);
    return 0;
}

/* Smoke-test driver: build a Vec, a Stack, and a Map, and exercise the whole
 * public API including the higher-order helpers from iter.c. */
int run(void) {
    Vec *v = vec_new();
    vec_push(v, 10);
    vec_push(v, 20);
    vec_apply(v, times_two);
    vec_clamp_all(v, 0, 15);
    size_t positives = vec_count_if(v, is_positive);
    long total = vec_reduce(v, add_up, 0);
    int first = 0;
    vec_get(v, 0, &first);
    vec_free(v);

    Stack *s = stack_new();
    stack_push(s, first);
    stack_push(s, (int)total);
    int top = 0;
    stack_pop(s, &top);
    size_t depth = stack_depth(s);
    stack_free(s);

    Map *m = map_new();
    map_put(m, "answer", 42);
    map_put(m, "positives", (int)positives);
    map_put(m, "depth", (int)depth);
    map_visit(m, print_entry, NULL);
    DSValue val = map_get_value(m, "answer");
    size_t size = map_size(m);
    printf("size=%zu top=%d val=%ld\n", size, top, val.data.as_int);
    return (int)val.data.as_int;
}
