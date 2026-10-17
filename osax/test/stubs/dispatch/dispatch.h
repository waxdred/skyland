// Minimal stand-in for the unit test of the payload (osax/test/payload_test.c):
// dispatch_async runs the block at once.
#pragma once
#include <stddef.h>

typedef struct dispatch_queue_s *dispatch_queue_t;
typedef void (^dispatch_block_t)(void);
#define DISPATCH_QUEUE_SERIAL NULL
dispatch_queue_t dispatch_queue_create(const char *label, void *attr);
void dispatch_async(dispatch_queue_t queue, dispatch_block_t block);
