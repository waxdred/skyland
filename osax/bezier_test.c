// xcrun clang osax/bezier_test.c -o .build/bezier_test && .build/bezier_test
#include <assert.h>
#include <stdio.h>
#include "bezier.h"

static int near(double a, double b) { return fabs(a - b) < 1e-3; }

int main(void)
{
    // linear curve is the identity
    for (double x = 0; x <= 1; x += 0.1) assert(near(bezier_ease(x, 0, 0, 1, 1), x));
    // CSS `ease` = cubic-bezier(0.25, 0.1, 0.25, 1), reference value at 0.5
    assert(near(bezier_ease(0.5, 0.25, 0.1, 0.25, 1), 0.8024));
    // ends are pinned, out of range is clamped
    assert(bezier_ease(0, 0.05, 0.9, 0.1, 1) == 0);
    assert(bezier_ease(1, 0.05, 0.9, 0.1, 1) == 1);
    assert(bezier_ease(-1, 0.05, 0.9, 0.1, 1) == 0);
    assert(bezier_ease(2, 0.05, 0.9, 0.1, 1) == 1);
    // 43PR easeOut (0.05, 0.9, 0.1, 1.0) is fast at the start and monotonic
    assert(bezier_ease(0.1, 0.05, 0.9, 0.1, 1) > 0.5);
    double prev = 0;
    for (double x = 0; x <= 1; x += 0.01) {
        double y = bezier_ease(x, 0.05, 0.9, 0.1, 1);
        assert(y >= prev - 1e-9);
        prev = y;
    }
    puts("bezier ok");
    return 0;
}
