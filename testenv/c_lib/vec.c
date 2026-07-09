#include "ds.h"

#include <stdlib.h>

/* Allocate an empty vector with a null backing buffer. Capacity is grown
 * lazily on the first push so an unused Vec costs almost nothing. */
Vec *vec_new(void) {
    Vec *v = malloc(sizeof(Vec));
    if (v == NULL) {
        return NULL;
    }
    v->data = NULL;
    v->len = 0;
    v->cap = 0;
    return v;
}

/* Internal: ensure there is room for at least one more element, reallocating
 * the backing store when the vector is full. Returns 0 on success, -1 on OOM. */
static int vec_grow(Vec *v) {
    size_t next;
    int *grown;

    if (v->cap == 0) {
        next = DS_INIT_CAP;
    } else {
        next = v->cap * DS_GROWTH;
    }
    grown = realloc(v->data, next * sizeof(int));
    if (grown == NULL) {
        return -1;
    }
    v->data = grown;
    v->cap = next;
    return 0;
}

/* Internal: true when i addresses a currently-live element. */
static int vec_in_bounds(const Vec *v, size_t i) {
    return i < v->len;
}

/* Append x, growing the buffer via vec_grow when it is full. */
int vec_push(Vec *v, int x) {
    if (v->len == v->cap) {
        if (vec_grow(v) != 0) {
            return DS_ERR_OOM;
        }
    }
    v->data[v->len] = x;
    v->len += 1;
    return DS_OK;
}

/* Remove the last element into *out. Returns DS_ERR_RANGE when empty. */
int vec_pop(Vec *v, int *out) {
    if (v->len == 0) {
        return DS_ERR_RANGE;
    }
    v->len -= 1;
    *out = v->data[v->len];
    return DS_OK;
}

/* Copy element i into *out. Returns DS_OK, or DS_ERR_RANGE when i is out of
 * range. Bounds are checked through vec_in_bounds. */
int vec_get(const Vec *v, size_t i, int *out) {
    if (!vec_in_bounds(v, i)) {
        return DS_ERR_RANGE;
    }
    *out = v->data[i];
    return DS_OK;
}

/* Intentionally dead (fixture): a shrink helper we never wire up. Uses the
 * DS_UNUSED macro so the parameter does not warn. */
static void vec_shrink_to_fit(Vec *v) {
    DS_UNUSED(v);
}

/* Release the backing buffer and the Vec itself. */
void vec_free(Vec *v) {
    if (v == NULL) {
        return;
    }
    free(v->data);
    free(v);
}
