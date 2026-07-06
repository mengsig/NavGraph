#include "ds.h"

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

/* Allocate an empty map with all buckets cleared. */
Map *map_new(void) {
    Map *m = calloc(1, sizeof(Map));
    return m;
}

/* Insert or overwrite k -> v. Returns 0 on success, -1 on allocation failure. */
int map_put(Map *m, const char *k, int v) {
    unsigned long b = hash(k);
    Entry *e = m->buckets[b];
    while (e != NULL) {
        if (strcmp(e->key, k) == 0) {
            e->value = v;
            return 0;
        }
        e = e->next;
    }
    e = malloc(sizeof(Entry));
    if (e == NULL) {
        return -1;
    }
    e->key = strdup(k);
    e->value = v;
    e->next = m->buckets[b];
    m->buckets[b] = e;
    m->count += 1;
    return 0;
}

/* Look up k, returning its value or -1 when absent. */
int map_get(Map *m, const char *k) {
    unsigned long b = hash(k);
    Entry *e = m->buckets[b];
    while (e != NULL) {
        if (strcmp(e->key, k) == 0) {
            return e->value;
        }
        e = e->next;
    }
    return -1;
}

/* Genuinely dead: never referenced anywhere in the library. Kept to exercise
 * dead-code detection. */
static void debug_dump(Map *m) {
    for (size_t i = 0; i < DS_MAP_BUCKETS; i += 1) {
        Entry *e = m->buckets[i];
        while (e != NULL) {
            printf("[%zu] %s=%d\n", i, e->key, e->value);
            e = e->next;
        }
    }
}

/* Smoke-test driver: build a Vec and a Map and exercise the public API. */
int run(void) {
    Vec *v = vec_new();
    vec_push(v, 10);
    vec_push(v, 20);
    vec_free(v);

    Map *m = map_new();
    map_put(m, "answer", 42);
    int got = map_get(m, "answer");
    printf("answer=%d\n", got);
    return got;
}
