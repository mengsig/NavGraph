#ifndef DS_H
#define DS_H

#include <stddef.h>

/* ---- Library version --------------------------------------------------- */
/* Object-like macros describing the library version. */
#define DS_VERSION_MAJOR 1
#define DS_VERSION_MINOR 4
/* Longest key a Map will copy; longer keys are rejected on insert. */
#define DS_MAX_KEY_LEN 256

/* ---- Tunables ---------------------------------------------------------- */
/* Initial capacity for a freshly-allocated dynamic array. */
#define DS_INIT_CAP 8
/* Multiplicative growth factor used when a Vec runs out of room. */
#define DS_GROWTH 2
/* Number of buckets in every Map (kept small for the demo). */
#define DS_MAP_BUCKETS 16

/* ---- Function-like macros ---------------------------------------------- */
/* Smaller / larger of two scalars (classic unhygienic C macros). */
#define DS_MIN(a, b) ((a) < (b) ? (a) : (b))
#define DS_MAX(a, b) ((a) > (b) ? (a) : (b))
/* Clamp x into the inclusive range [lo, hi]. */
#define DS_CLAMP(x, lo, hi) DS_MIN(DS_MAX((x), (lo)), (hi))
/* Element count of a fixed-size C array. */
#define DS_ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
/* Silence unused-parameter warnings without a cast at each call site. */
#define DS_UNUSED(x) ((void)(x))

/* ---- Status codes ------------------------------------------------------ */
/* Result of a fallible container operation. Zero is success. */
enum DSStatus {
    DS_OK = 0,
    DS_ERR_OOM = -1,
    DS_ERR_NOTFOUND = -2,
    DS_ERR_RANGE = -3
};
typedef enum DSStatus DSStatus;

/* ---- Tagged values ----------------------------------------------------- */
/* Discriminator selecting the active member of DSValueData. */
enum DSKind {
    DS_KIND_INT,
    DS_KIND_STR,
    DS_KIND_PTR
};
typedef enum DSKind DSKind;

/* Payload of a tagged value; interpret per the owning DSValue.kind. */
union DSValueData {
    long as_int;
    char *as_str;
    void *as_ptr;
};
typedef union DSValueData DSValueData;

/* A dynamically-typed value carried by the higher-level helpers. */
struct DSValue {
    DSKind kind;
    DSValueData data;
};
typedef struct DSValue DSValue;

/* Optional sink for diagnostic messages. Intentionally dead (fixture): no
 * symbol takes a DSLogger, so this typedef exercises unused-type detection on
 * function-pointer typedefs. */
typedef void (*DSLogger)(const char *msg);

/* ---- Core containers --------------------------------------------------- */
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

/* Snapshot of a Map's shape. Intentionally dead (fixture): nothing fills or
 * reads this type; it exists as a target for unused-type detection. */
struct MapStats {
    size_t entries;
    size_t used_buckets;
    size_t longest_chain;
};
typedef struct MapStats MapStats;

/* ---- Vec API ----------------------------------------------------------- */
Vec *vec_new(void);
int vec_push(Vec *v, int x);
int vec_pop(Vec *v, int *out);
int vec_get(const Vec *v, size_t i, int *out);
void vec_free(Vec *v);

/* ---- Map API ----------------------------------------------------------- */
Map *map_new(void);
int map_put(Map *m, const char *k, int v);
int map_get(Map *m, const char *k);
size_t map_size(const Map *m);

/* Driver used by the demo main(). */
int run(void);

#endif /* DS_H */
