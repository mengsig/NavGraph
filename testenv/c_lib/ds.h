#ifndef DS_H
#define DS_H

#include <stddef.h>

/* Initial capacity for a freshly-allocated dynamic array. */
#define DS_INIT_CAP 8
/* Multiplicative growth factor used when a Vec runs out of room. */
#define DS_GROWTH 2
/* Number of buckets in every Map (kept prime-ish and small for the demo). */
#define DS_MAP_BUCKETS 16

/* A growable array of ints. */
struct Vec {
    int *data;
    size_t len;
    size_t cap;
};
typedef struct Vec Vec;

/* One key/value pair living in a Map bucket chain. */
struct Entry {
    char *key;
    int value;
    struct Entry *next;
};
typedef struct Entry Entry;

/* A tiny separate-chaining hash map from C strings to ints. */
struct Map {
    Entry *buckets[DS_MAP_BUCKETS];
    size_t count;
};
typedef struct Map Map;

/* Vec API. */
Vec *vec_new(void);
int vec_push(Vec *v, int x);
void vec_free(Vec *v);

/* Map API. */
Map *map_new(void);
int map_put(Map *m, const char *k, int v);
int map_get(Map *m, const char *k);

/* Driver used by the demo main(). */
int run(void);

#endif /* DS_H */
