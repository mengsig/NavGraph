#ifndef ITER_H
#define ITER_H

#include "ds.h"

/* ---- Callback typedefs (function pointers) ----------------------------- */
/* Map an int to another int (used for in-place transforms). */
typedef int (*IntTransform)(int x);
/* Test an int, returning nonzero to accept it. */
typedef int (*IntPredicate)(int x);
/* Fold an accumulator with the next element. */
typedef long (*IntReducer)(long acc, int x);
/* Visit one Map entry; return nonzero to stop iteration early. */
typedef int (*MapVisitor)(const char *key, int value, void *ctx);

/* A pull-style cursor over a Vec. The next member returns DS_OK and writes the
 * element through out, or DS_ERR_RANGE at end of sequence. */
struct VecIter {
    const Vec *vec;
    size_t pos;
    int (*next)(struct VecIter *it, int *out);
};
typedef struct VecIter VecIter;

/* ---- Vec algorithms ---------------------------------------------------- */
void vec_apply(Vec *v, IntTransform f);
void vec_clamp_all(Vec *v, int lo, int hi);
size_t vec_count_if(const Vec *v, IntPredicate p);
long vec_reduce(const Vec *v, IntReducer f, long init);
VecIter vec_iter(const Vec *v);

/* ---- Map algorithms ---------------------------------------------------- */
int map_visit(Map *m, MapVisitor f, void *ctx);
DSValue map_get_value(Map *m, const char *k);

#endif /* ITER_H */
