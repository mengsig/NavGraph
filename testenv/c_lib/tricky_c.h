#ifndef TRICKY_C_H
#define TRICKY_C_H

#include "ds.h"

/* ---- Macros that hide real code ---------------------------------------- */
/* Function-like macro that DEFINES a function: the definition only exists
 * after preprocessing, which a lexical scan never sees. */
#define TRICKY_DEFINE_SCALER(name, factor) \
    int name(int x) { return x * (factor); }

/* Macro expanding to a call, hiding the callee behind a parameter. */
#define TRICKY_APPLY(fn, arg) fn(arg)

/* ---- Nested and anonymous aggregates ----------------------------------- */
/* A node whose header is a named inner struct and whose payload is an
 * anonymous union. */
struct TrickyNode {
    struct TrickyHeader {
        int tag;
        size_t size;
    } header;
    union {
        long as_long;
        void *as_ptr;
    } payload;
    struct TrickyNode *next;
};
typedef struct TrickyNode TrickyNode;

/* ---- C's interface: a table of function pointers ----------------------- */
struct TrickyOps {
    int (*init)(TrickyNode *self, int tag);
    int (*step)(TrickyNode *self, int by);
    const char *(*name)(void);
};
typedef struct TrickyOps TrickyOps;

/* An inline definition living in the header, not in a .c file. */
static inline int tricky_tag_of(const TrickyNode *n) {
    return n->header.tag;
}

/* Signature split across four lines. */
int tricky_chain(
    TrickyNode *head,
    const TrickyOps *ops,
    int by
);

const TrickyOps *tricky_default_ops(void);
int tricky_variadic_sum(int count, ...);
int tricky_run(void);

#endif /* TRICKY_C_H */
