#include "iter.h"

#include <stddef.h>

/* Internal: read v->data[i]; callers guarantee i < len. Shared by the read-only
 * algorithms below so bounds logic lives in one place. */
static int at(const Vec *v, size_t i) {
    return v->data[i];
}

/* Apply f to every element in place. */
void vec_apply(Vec *v, IntTransform f) {
    for (size_t i = 0; i < v->len; i += 1) {
        v->data[i] = f(v->data[i]);
    }
}

/* Clamp every element into [lo, hi] in place using the DS_CLAMP macro. */
void vec_clamp_all(Vec *v, int lo, int hi) {
    for (size_t i = 0; i < v->len; i += 1) {
        v->data[i] = DS_CLAMP(v->data[i], lo, hi);
    }
}

/* Count elements for which p returns nonzero. */
size_t vec_count_if(const Vec *v, IntPredicate p) {
    size_t n = 0;
    for (size_t i = 0; i < v->len; i += 1) {
        if (p(at(v, i))) {
            n += 1;
        }
    }
    return n;
}

/* Left fold: start from init, then acc = f(acc, e) across the vector. */
long vec_reduce(const Vec *v, IntReducer f, long init) {
    long acc = init;
    for (size_t i = 0; i < v->len; i += 1) {
        acc = f(acc, at(v, i));
    }
    return acc;
}

/* Internal: the next() implementation backing every VecIter. Referenced only
 * by assignment to the VecIter.next function pointer in vec_iter. */
static int vec_iter_next(VecIter *it, int *out) {
    if (it->pos >= it->vec->len) {
        return DS_ERR_RANGE;
    }
    *out = at(it->vec, it->pos);
    it->pos += 1;
    return DS_OK;
}

/* Build a fresh cursor positioned at the start of v. */
VecIter vec_iter(const Vec *v) {
    VecIter it;
    it.vec = v;
    it.pos = 0;
    it.next = vec_iter_next;
    return it;
}

/* Call f for every live entry; stop early when f returns nonzero. Returns the
 * number of entries visited. */
int map_visit(Map *m, MapVisitor f, void *ctx) {
    int visited = 0;
    for (size_t b = 0; b < DS_MAP_BUCKETS; b += 1) {
        Entry *e = m->buckets[b];
        while (e != NULL) {
            visited += 1;
            if (f(e->key, e->value, ctx) != 0) {
                return visited;
            }
            e = e->next;
        }
    }
    return visited;
}

/* Look up k and wrap the result in a tagged DSValue. Absent keys yield a
 * DS_KIND_PTR value holding NULL. Bridges into map.c via map_get. */
DSValue map_get_value(Map *m, const char *k) {
    DSValue out;
    int found = map_get(m, k);
    if (found < 0) {
        out.kind = DS_KIND_PTR;
        out.data.as_ptr = NULL;
        return out;
    }
    out.kind = DS_KIND_INT;
    out.data.as_int = found;
    return out;
}

/* Intentionally dead (fixture): a spare reducer nobody wires up. Matches the
 * IntReducer signature but is never referenced. */
static long sum_reducer(long acc, int x) {
    return acc + x;
}
