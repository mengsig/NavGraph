#ifndef STACK_H
#define STACK_H

#include "ds.h"

/* A LIFO stack layered on top of a Vec. Owns its backing store. */
struct Stack {
    Vec *backing;
};
typedef struct Stack Stack;

/* Stack API. */
Stack *stack_new(void);
int stack_push(Stack *s, int x);
int stack_pop(Stack *s, int *out);
int stack_peek(const Stack *s, int *out);
size_t stack_depth(const Stack *s);
void stack_free(Stack *s);

#endif /* STACK_H */
