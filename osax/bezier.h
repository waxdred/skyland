// Cubic bezier easing with P0 = (0,0), P3 = (1,1) and control points
// (x1,y1), (x2,y2), same definition as Hyprland `bezier = name, x1, y1, x2, y2`
// and CSS cubic-bezier(). Returns the eased progress for linear progress x.
#ifndef SKYLAND_BEZIER_H
#define SKYLAND_BEZIER_H

#include <math.h>

static double bezier_axis(double t, double a, double b)
{
    return ((1 - 3 * b + 3 * a) * t + (3 * b - 6 * a)) * t * t + 3 * a * t;
}

static double bezier_axis_slope(double t, double a, double b)
{
    return 3 * (1 - 3 * b + 3 * a) * t * t + 2 * (3 * b - 6 * a) * t + 3 * a;
}

static double bezier_ease(double x, double x1, double y1, double x2, double y2)
{
    if (x <= 0) return 0;
    if (x >= 1) return 1;
    // solve bezier_axis(t, x1, x2) == x: Newton first, bisection if it misbehaves
    double t = x;
    for (int i = 0; i < 8; ++i) {
        double err = bezier_axis(t, x1, x2) - x;
        double slope = bezier_axis_slope(t, x1, x2);
        if (fabs(err) < 1e-7 || fabs(slope) < 1e-7) break;
        t -= err / slope;
    }
    if (t < 0 || t > 1 || fabs(bezier_axis(t, x1, x2) - x) > 1e-5) {
        double lo = 0, hi = 1;
        t = x;
        for (int i = 0; i < 40; ++i) {
            if (bezier_axis(t, x1, x2) < x) lo = t; else hi = t;
            t = (lo + hi) / 2;
        }
    }
    return bezier_axis(t, y1, y2);
}

#endif
