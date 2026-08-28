#include "tricky_c.h"
#include "iter.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* Same name as map.c's file-local `hash`: two static definitions, one name,
 * two translation units. */
static unsigned long hash(const char *key) {
    unsigned long h = 0;
    while (*key != '\0') {
        h = h * 31u + (unsigned char)(*key);
        key += 1;
    }
    return h;
}

/* A file-scope name a local below shadows. */
static int budget = 32;

/* Defined by the macro: neither name appears as a `int name(...)` in the
 * source text. */
TRICKY_DEFINE_SCALER(tricky_double, 2)
TRICKY_DEFINE_SCALER(tricky_triple, 3)

static int node_init(TrickyNode *self, int tag) {
    self->header.tag = tag;
    self->header.size = sizeof(TrickyNode);
    return tag;
}

static int node_step(TrickyNode *self, int by) {
    self->payload.as_long += by;
    return by;
}

static const char *node_name(void) {
    return "tricky";
}

/* Designated initializers wiring three file-local functions into the table. */
static const TrickyOps default_ops = {
    .init = node_init,
    .step = node_step,
    .name = node_name,
};

const TrickyOps *tricky_default_ops(void) {
    return &default_ops;
}

/* Calls both table members through the pointer, and the header's inline fn. */
int tricky_chain(TrickyNode *head, const TrickyOps *ops, int by) {
    int moved = 0;
    for (TrickyNode *n = head; n != NULL; n = n->next) {
        ops->init(n, tricky_tag_of(n));
        moved += ops->step(n, by);
    }
    return moved;
}

int tricky_variadic_sum(int count, ...) {
    va_list ap;
    int total = 0;
    va_start(ap, count);
    for (int i = 0; i < count; i += 1) {
        total += va_arg(ap, int);
    }
    va_end(ap);
    return total;
}

/* The local `budget` hides the file-scope `budget`. */
static int shadow_budget(int n) {
    int budget = 4;
    return n * budget;
}

/* Code-shaped text in a string literal and in a comment: data, not symbols. */
static const char *tricky_banner =
    "int phantom_from_string(void) { return 0; }\n"
    "struct PhantomStruct { int x; };\n";
/* int phantom_from_comment(void) { return 0; } */

int tricky_run(void) {
    TrickyNode b = { { 2, 0 }, { 0 }, NULL };
    TrickyNode a = { { 1, 0 }, { 0 }, &b };
    const TrickyOps *ops = tricky_default_ops();
    int moved = tricky_chain(&a, ops, 3);
    int doubled = TRICKY_APPLY(tricky_double, moved);
    int tripled = tricky_triple(doubled);
    unsigned long h = hash(node_name());

    Vec *v = vec_new();
    vec_push(v, tripled);
    VecIter it = vec_iter(v);
    int out = 0;
    it.next(&it, &out);
    vec_free(v);

    int total = tricky_variadic_sum(3, out, (int)h, shadow_budget(budget));
    printf("%s", tricky_banner);
    return total + DS_CLAMP(total, 0, 100);
}
