#include "stack.h"

#include <stdlib.h>

/* Allocate an empty stack backed by a fresh Vec. Frees the shell and returns
 * NULL if either allocation fails. */
Stack *stack_new(void) {
    Stack *s = malloc(sizeof(Stack));
    if (s == NULL) {
        return NULL;
    }
    s->backing = vec_new();
    if (s->backing == NULL) {
        free(s);
        return NULL;
    }
    return s;
}

/* Push x onto the top of the stack. Delegates to vec_push. */
int stack_push(Stack *s, int x) {
    return vec_push(s->backing, x);
}

/* Pop the top element into *out. Delegates to vec_pop, which reports
 * DS_ERR_RANGE when the stack is empty. */
int stack_pop(Stack *s, int *out) {
    return vec_pop(s->backing, out);
}

/* Peek at the top element without removing it. */
int stack_peek(const Stack *s, int *out) {
    Vec *v = s->backing;
    if (v->len == 0) {
        return DS_ERR_RANGE;
    }
    return vec_get(v, v->len - 1, out);
}

/* Number of elements currently on the stack. */
size_t stack_depth(const Stack *s) {
    return s->backing->len;
}

/* Release the stack and its backing store. */
void stack_free(Stack *s) {
    if (s == NULL) {
        return;
    }
    vec_free(s->backing);
    free(s);
}
