// Minimal stand-in for the unit test of the payload (osax/test/payload_test.c).
#pragma once
#include <stdint.h>

typedef struct __CVDisplayLink *CVDisplayLinkRef;
typedef struct { int64_t videoTime; } CVTimeStamp;
typedef uint64_t CVOptionFlags;
typedef int32_t CVReturn;
enum { kCVReturnSuccess = 0 };
typedef CVReturn (*CVDisplayLinkOutputCallback)(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out,
                                                CVOptionFlags flags_in, CVOptionFlags *flags_out, void *context);
CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *link);
CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link, CVDisplayLinkOutputCallback callback, void *context);
CVReturn CVDisplayLinkStart(CVDisplayLinkRef link);
CVReturn CVDisplayLinkStop(CVDisplayLinkRef link);
