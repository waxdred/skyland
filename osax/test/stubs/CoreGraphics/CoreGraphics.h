// Minimal stand-in for the unit test of the payload (osax/test/payload_test.c).
#pragma once
#include <stdint.h>

typedef double CGFloat;
typedef struct { CGFloat x, y; } CGPoint;
typedef struct { CGFloat width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;
typedef struct { CGFloat a, b, c, d, tx, ty; } CGAffineTransform;
typedef int32_t CGError;
enum { kCGErrorSuccess = 0, kCGErrorFailure = 1000 };
typedef int32_t CGWindowLevel;
typedef int32_t CGWindowLevelKey;
enum { kCGNormalWindowLevelKey = 4, kCGFloatingWindowLevelKey = 5, kCGModalPanelWindowLevelKey = 8 };

static const CGRect CGRectZero = { { 0, 0 }, { 0, 0 } };

static inline CGRect CGRectMake(CGFloat x, CGFloat y, CGFloat width, CGFloat height)
{
    CGRect r = { { x, y }, { width, height } };
    return r;
}

static inline CGAffineTransform CGAffineTransformMakeTranslation(CGFloat tx, CGFloat ty)
{
    CGAffineTransform t = { 1, 0, 0, 1, tx, ty };
    return t;
}

static inline CGAffineTransform CGAffineTransformMakeScale(CGFloat sx, CGFloat sy)
{
    CGAffineTransform t = { sx, 0, 0, sy, 0, 0 };
    return t;
}

// t1 then t2, like CoreGraphics
static inline CGAffineTransform CGAffineTransformConcat(CGAffineTransform t1, CGAffineTransform t2)
{
    CGAffineTransform r = {
        t1.a * t2.a + t1.b * t2.c, t1.a * t2.b + t1.b * t2.d,
        t1.c * t2.a + t1.d * t2.c, t1.c * t2.b + t1.d * t2.d,
        t1.tx * t2.a + t1.ty * t2.c + t2.tx, t1.tx * t2.b + t1.ty * t2.d + t2.ty,
    };
    return r;
}

static inline CGWindowLevel CGWindowLevelForKey(CGWindowLevelKey key) { return key; }
