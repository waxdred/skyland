// Skyland payload, injected into Dock.app by loader.m.
// Dock owns the universal SkyLight connection, so window changes issued from
// here apply to every app's windows (from any other process they are ignored).
//
// Protocol: text lines on /tmp/skyland-sa_$USER.socket, one command per line and
// one reply per line, "ok\n" or "err <reason>\n"; several lines per connection
// ("batch" in ping), or one (older apps).
//   ping                               (replies "ok fade close": capabilities, old payloads reply less)
//   corner <wid> <radius>
//   uncorner <wid>                     (back to the system radius)
//   alpha <wid> <alpha>                (cancels a running fade)
//   fade <wid> <alpha> <ms> <x1> <y1> <x2> <y2> [<from>]
//       step the alpha from its current value (or <from>) along the bezier, like yabai's
//       opacity_fade: stepped every display frame, no WindowServer fade.
//   animate <wid> <x> <y> <w> <h> <ms> <x1> <y1> <x2> <y2> [<tx> <ty> <tw> <th> [hold]]
//       show the window at rect (x,y,w,h) then move it to its real frame over
//       <ms> following the cubic bezier (x1,y1,x2,y2). With a target rect it moves
//       there instead and jumps to its real frame at the end (slide-out of a
//       window being hidden), or stays there with hold = 1 (window being closed).
//       Stepped here every display frame with a window transform, never with a
//       WindowServer-side animation.
//   untransform <wid>                  (back to its real frame, stops an animation)
//   blur <wid> <radius>                (blur behind the window's translucent pixels, 0 = none)
//   shadow <wid> 0|1                   (0: no shadow, its parameters kept; 1: back as it was)
//   dim <wid> <amount> [<ms> <x1> <y1> <x2> <y2> <from>]
//       darken the window, 0 = normal, 1 = black (SLSSetWindowListBrightness, negative
//       brightness); with a duration, stepped from <from> along the bezier like fade.
//   track <wid> <ms> <mode> <channels> <n> (<x> <y> <w> <h> <alpha> <brightness>) * n
//       play a sampled animation (SkylandAnimation styles, Sources/SkylandAnimation):
//       n samples evenly spaced over <ms>, linear in between (the curve is in the
//       samples). channels: 1 frame, 2 alpha, 4 brightness (-1 black .. 1 white),
//       added up. mode 0: the rects are mapped onto the window's real frame through
//       the last one (the frame the track ends at: the app may apply a slightly
//       different one), back to the real frame at the end; 1: screen rects, back to
//       the real frame at the end (window moved away, workspace switched); 2: screen
//       rects, stays at the last one (window being closed). A later fade / alpha,
//       dim, animate / untransform takes its channel over, the track goes on with
//       the others.
//
// Signatures from REA decompilation of SkyLight on macOS 15.6.1 (24G90),
// see vault note "SkyLight private API recon".

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "bezier.h"

extern int SLSMainConnectionID(void);
extern CFTypeRef SLSTransactionCreate(int cid);
extern int SLSTransactionCommit(CFTypeRef t, int sync);
extern void SLSTransactionSetWindowCornerRadius(CFTypeRef t, uint32_t wid, double radius);
extern void SLSTransactionClearWindowCornerRadius(CFTypeRef t, uint32_t wid);
// Never use SLSTransactionSetWindowAlphaAnimated: a fade still running when its
// window closes makes the next alpha change crash WindowServer in
// CGXWindow::fade_finish (seen 2026-10-14, logs the user out).
extern void SLSTransactionSetWindowAlpha(CFTypeRef t, uint32_t wid, float alpha);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
// brightness -1 (black) .. 0 (normal) .. 1 (white), checked on macOS 15.6.1
extern CGError SLSSetWindowListBrightness(int cid, uint32_t *wids, float *brightness, int count);
// blur of what is behind the window's translucent pixels; radius 0 = none (checked on 15.6.1)
extern CGError SLSSetWindowBackgroundBlurRadius(int cid, uint32_t wid, uint32_t radius);
// shadow: gaussian sigma, density (0 = no shadow), offset, rim (checked on 15.6.1;
// a titled window reads 32.9, 0.7, 0, 18, 0)
extern CGError SLSGetWindowShadowAndRimParameters(int cid, uint32_t wid, float *sigma, float *density, int *dx, int *dy, int *rim);
extern CGError SLSSetWindowShadowAndRimParameters(int cid, uint32_t wid, float sigma, float density, int dx, int dy, int rim);
// transaction variants, disassembled on 15.6.1 (weak: the direct calls above otherwise)
extern void SLSTransactionSetWindowTransform(CFTypeRef t, uint32_t wid, int unknown1, int unknown2,
                                             CGAffineTransform transform) __attribute__((weak_import));
extern void SLSTransactionSetWindowBrightness(CFTypeRef t, uint32_t wid, float brightness) __attribute__((weak_import));

// All running animations (window frame, alpha, dim) live in one table, stepped by
// one CVDisplayLink callback in sync with the display: every window of a workspace
// switch changes in the same frame, through one SkyLight transaction per frame.
// A newer animation of the same kind on the same window replaces the running one.
// The display link only runs while the table is not empty.
// ponytail: one display link (the main display's); windows on another display with
// a different refresh rate are stepped at the main display's rate.
enum anim_kind { ANIM_FRAME, ANIM_ALPHA, ANIM_DIM, ANIM_TRACK };
enum { TRACK_FRAME = 1, TRACK_ALPHA = 2, TRACK_BRIGHTNESS = 4 };
enum { TRACK_ENTER = 0, TRACK_LEAVE = 1, TRACK_HOLD = 2 };
#define MAX_TRACK_SAMPLES 240
struct anim {
    int used;
    enum anim_kind kind;
    uint32_t wid;
    double start, ms, x1, y1, x2, y2;
    int frames;
    CGRect real;           // the window's real frame, re-read now and then
    CGRect from, to;       // ANIM_FRAME: visual rects
    int has_to, hold;
    float value_from, value_to; // ANIM_ALPHA / ANIM_DIM
    float *samples;        // ANIM_TRACK: nsamples * (x, y, w, h, alpha, brightness), owned
    int nsamples, mode, channels;
};
#define MAX_ANIMS 256
static struct anim anims[MAX_ANIMS];
static pthread_mutex_t anim_lock = PTHREAD_MUTEX_INITIALIZER;
static CVDisplayLinkRef display_link;
static int display_link_running; // only touched on link_queue
static dispatch_queue_t link_queue; // serializes CVDisplayLinkStart / Stop

// Frees a slot (and the samples of a track). Called with anim_lock held.
static void release_anim(struct anim *a)
{
    free(a->samples);
    a->samples = NULL;
    a->used = 0;
}

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

// The window transform maps screen points to window points; at rest it is a
// translation by -origin. Showing a window of real frame `real` at `visual`:
// p -> (p - visual.origin) * real.size / visual.size.
static CGAffineTransform transform_showing(CGRect real, CGRect visual)
{
    return CGAffineTransformConcat(
        CGAffineTransformMakeTranslation(-visual.origin.x, -visual.origin.y),
        CGAffineTransformMakeScale(real.size.width / visual.size.width, real.size.height / visual.size.height));
}

// Transaction setters when this SkyLight has them (checked on 15.6.1: wid, two
// ints yabai passes as 0, the transform), else the direct calls, one per window.
static void set_transform(CFTypeRef t, int cid, uint32_t wid, CGAffineTransform transform)
{
    if (t && SLSTransactionSetWindowTransform) SLSTransactionSetWindowTransform(t, wid, 0, 0, transform);
    else SLSSetWindowTransform(cid, wid, transform);
}

static void set_alpha(CFTypeRef t, int cid, uint32_t wid, float alpha)
{
    if (t) SLSTransactionSetWindowAlpha(t, wid, alpha);
    else SLSSetWindowAlpha(cid, wid, alpha);
}

// brightness -1 (black) .. 0 (normal) .. 1 (white)
static void set_brightness(CFTypeRef t, int cid, uint32_t wid, float brightness)
{
    if (t && SLSTransactionSetWindowBrightness) SLSTransactionSetWindowBrightness(t, wid, brightness);
    else SLSSetWindowListBrightness(cid, &wid, &brightness, 1);
}

// dim amount 0 (normal) .. 1 (black) = brightness 0 .. -1
static void set_dim(CFTypeRef t, int cid, uint32_t wid, float amount)
{
    set_brightness(t, cid, wid, -amount);
}

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

// A track rect mapped onto the window's real frame through the track's last rect
// (the frame it ends at): the app may have applied a slightly different frame.
static CGRect onto_real(CGRect v, const float *end, CGRect real)
{
    double sx = real.size.width / end[2], sy = real.size.height / end[3];
    return CGRectMake(real.origin.x + (v.origin.x - end[0]) * sx, real.origin.y + (v.origin.y - end[1]) * sy,
                      v.size.width * sx, v.size.height * sy);
}

static void stop_link_if_idle(void)
{
    dispatch_async(link_queue, ^{
        pthread_mutex_lock(&anim_lock);
        int idle = 1;
        for (int i = 0; i < MAX_ANIMS && idle; i++) idle = !anims[i].used;
        pthread_mutex_unlock(&anim_lock);
        // outside the lock: Stop waits for a running callback, which takes the lock
        if (idle && display_link_running) { CVDisplayLinkStop(display_link); display_link_running = 0; }
    });
}

static void start_link(void)
{
    dispatch_async(link_queue, ^{
        if (!display_link_running && CVDisplayLinkStart(display_link) == kCVReturnSuccess) display_link_running = 1;
    });
}

static CVReturn step(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *out, CVOptionFlags flags_in,
                     CVOptionFlags *flags_out, void *context)
{
    int cid = SLSMainConnectionID();
    double t_now = now_ms();
    CFTypeRef t = SLSTransactionCreate(cid);
    int active = 0;
    pthread_mutex_lock(&anim_lock);
    for (int i = 0; i < MAX_ANIMS; i++) {
        struct anim *a = &anims[i];
        if (!a->used) continue;
        // the real frame: every frame at first (the app applies the new frame a bit
        // after it starts the animation), then every 4th frame, which also notices
        // a window that is gone
        if (t_now - a->start < 200 || a->frames % 4 == 0) {
            if (SLSGetWindowBounds(cid, a->wid, &a->real) != kCGErrorSuccess) { release_anim(a); continue; }
        }
        a->frames++;
        double x = (t_now - a->start) / a->ms;
        double p = x >= 1 ? 1 : bezier_ease(x, a->x1, a->y1, a->x2, a->y2);
        switch (a->kind) {
            case ANIM_FRAME: {
                if (x >= 1) {
                    set_transform(t, cid, a->wid, a->hold
                        ? transform_showing(a->real, a->to) // closing window: stays small
                        : CGAffineTransformMakeTranslation(-a->real.origin.x, -a->real.origin.y));
                    release_anim(a);
                    break;
                }
                CGRect to = a->has_to ? a->to : a->real;
                CGRect v = CGRectMake(
                    a->from.origin.x + (to.origin.x - a->from.origin.x) * p,
                    a->from.origin.y + (to.origin.y - a->from.origin.y) * p,
                    a->from.size.width + (to.size.width - a->from.size.width) * p,
                    a->from.size.height + (to.size.height - a->from.size.height) * p);
                if (v.size.width >= 1 && v.size.height >= 1) set_transform(t, cid, a->wid, transform_showing(a->real, v));
                break;
            }
            case ANIM_ALPHA:
            case ANIM_DIM: {
                float value = a->value_from + (a->value_to - a->value_from) * (float) p;
                if (a->kind == ANIM_ALPHA) set_alpha(t, cid, a->wid, value); else set_dim(t, cid, a->wid, value);
                if (x >= 1) release_anim(a);
                break;
            }
            case ANIM_TRACK: {
                // the two samples around now, linear in between
                int last = a->nsamples - 1;
                double pos = (x >= 1 ? 1 : x < 0 ? 0 : x) * last;
                int i = pos >= last ? last - 1 : (int) pos;
                double f = pos - i;
                const float *s = a->samples + 6 * i, *n = s + 6;
                CGRect v = CGRectMake(s[0] + (n[0] - s[0]) * f, s[1] + (n[1] - s[1]) * f,
                                      s[2] + (n[2] - s[2]) * f, s[3] + (n[3] - s[3]) * f);
                if (a->channels & TRACK_FRAME) {
                    if (a->mode == TRACK_ENTER) v = onto_real(v, a->samples + 6 * last, a->real);
                    if (x >= 1 && a->mode != TRACK_HOLD) {
                        set_transform(t, cid, a->wid, CGAffineTransformMakeTranslation(-a->real.origin.x, -a->real.origin.y));
                    } else if (v.size.width >= 1 && v.size.height >= 1) {
                        set_transform(t, cid, a->wid, transform_showing(a->real, v));
                    }
                }
                if (a->channels & TRACK_ALPHA) set_alpha(t, cid, a->wid, clampf(s[4] + (n[4] - s[4]) * (float) f, 0, 1));
                if (a->channels & TRACK_BRIGHTNESS) {
                    set_brightness(t, cid, a->wid, clampf(s[5] + (n[5] - s[5]) * (float) f, -1, 1));
                }
                if (x >= 1) release_anim(a);
                break;
            }
        }
        active += a->used;
    }
    pthread_mutex_unlock(&anim_lock);
    if (t) { SLSTransactionCommit(t, 0); CFRelease(t); }
    if (!active) stop_link_if_idle();
    return kCVReturnSuccess;
}

// Adds (or replaces the running animation of the same kind on the same window).
static const char *add_anim(struct anim a)
{
    a.used = 1;
    a.start = now_ms();
    pthread_mutex_lock(&anim_lock);
    struct anim *slot = NULL;
    for (int i = 0; i < MAX_ANIMS; i++) {
        if (anims[i].used && anims[i].kind == a.kind && anims[i].wid == a.wid) { slot = &anims[i]; break; }
        if (!anims[i].used && !slot) slot = &anims[i];
    }
    if (slot) {
        release_anim(slot); // the samples of a track it replaces
        *slot = a;
    }
    pthread_mutex_unlock(&anim_lock);
    if (!slot) return "err too many animations\n";
    start_link();
    return "ok\n";
}

static void cancel_anim(enum anim_kind kind, uint32_t wid)
{
    pthread_mutex_lock(&anim_lock);
    for (int i = 0; i < MAX_ANIMS; i++) {
        if (anims[i].used && anims[i].kind == kind && anims[i].wid == wid) release_anim(&anims[i]);
    }
    pthread_mutex_unlock(&anim_lock);
}

// A command for a channel a running track drives takes it over: the track goes on
// with its other channels (an `alpha` during a track: the track keeps the frame).
static void strip_track(uint32_t wid, int channels)
{
    pthread_mutex_lock(&anim_lock);
    for (int i = 0; i < MAX_ANIMS; i++) {
        struct anim *a = &anims[i];
        if (!a->used || a->kind != ANIM_TRACK || a->wid != wid) continue;
        a->channels &= ~channels;
        if (!a->channels) release_anim(a);
    }
    pthread_mutex_unlock(&anim_lock);
}

static const char *start_fade(uint32_t wid, double *args, int argc)
{
    if (args[0] < 0 || args[0] > 1 || args[1] <= 0) return "err bad alpha or duration\n";
    if (argc == 7 && (args[6] < 0 || args[6] > 1)) return "err bad start alpha\n";
    strip_track(wid, TRACK_ALPHA);
    float from = 1;
    if (argc == 7) from = (float) args[6];
    else SLSGetWindowAlpha(SLSMainConnectionID(), wid, &from);
    return add_anim((struct anim) {
        .kind = ANIM_ALPHA, .wid = wid, .value_from = from, .value_to = (float) args[0],
        .ms = args[1], .x1 = args[2], .y1 = args[3], .x2 = args[4], .y2 = args[5],
    });
}

static const char *start_dim(uint32_t wid, double *args, int argc)
{
    if (args[0] < 0 || args[0] > 1) return "err bad amount\n";
    strip_track(wid, TRACK_BRIGHTNESS);
    if (argc == 1) {
        cancel_anim(ANIM_DIM, wid); // stops a running dim fade
        set_dim(NULL, SLSMainConnectionID(), wid, (float) args[0]);
        return "ok\n";
    }
    if (args[1] <= 0 || args[6] < 0 || args[6] > 1) return "err bad duration or start amount\n";
    return add_anim((struct anim) {
        .kind = ANIM_DIM, .wid = wid, .value_from = (float) args[6], .value_to = (float) args[0],
        .ms = args[1], .x1 = args[2], .y1 = args[3], .x2 = args[4], .y2 = args[5],
    });
}

static const char *start_animation(uint32_t wid, double *args, int argc)
{
    if (args[2] < 1 || args[3] < 1 || args[4] <= 0) return "err bad rect or duration\n";
    if (argc >= 13 && (args[11] < 1 || args[12] < 1)) return "err bad target rect\n";
    strip_track(wid, TRACK_FRAME);
    return add_anim((struct anim) {
        .kind = ANIM_FRAME, .wid = wid, .from = CGRectMake(args[0], args[1], args[2], args[3]),
        .ms = args[4], .x1 = args[5], .y1 = args[6], .x2 = args[7], .y2 = args[8],
        .has_to = argc >= 13, .to = argc >= 13 ? CGRectMake(args[9], args[10], args[11], args[12]) : CGRectZero,
        .hold = argc == 14 && args[13] != 0,
    });
}

// Shadows turned off, with what to restore. ponytail: fixed table, a full one stops saving
#define MAX_SHADOWS 512
static struct { uint32_t wid; float sigma, density; int dx, dy, rim; } shadows[MAX_SHADOWS];
static pthread_mutex_t shadow_lock = PTHREAD_MUTEX_INITIALIZER;

static const char *set_shadow(uint32_t wid, int on)
{
    int cid = SLSMainConnectionID();
    pthread_mutex_lock(&shadow_lock);
    int found = -1, free_slot = -1;
    for (int i = 0; i < MAX_SHADOWS; i++) {
        if (shadows[i].wid == wid) found = i;
        if (!shadows[i].wid && free_slot < 0) free_slot = i;
    }
    const char *reply = "ok\n";
    if (!on && found < 0) { // save, then off
        float sigma, density;
        int dx, dy, rim;
        if (SLSGetWindowShadowAndRimParameters(cid, wid, &sigma, &density, &dx, &dy, &rim) != kCGErrorSuccess) reply = "err no window\n";
        else if (free_slot < 0) reply = "err too many windows\n";
        else {
            shadows[free_slot].wid = wid;
            shadows[free_slot].sigma = sigma; shadows[free_slot].density = density;
            shadows[free_slot].dx = dx; shadows[free_slot].dy = dy; shadows[free_slot].rim = rim;
            SLSSetWindowShadowAndRimParameters(cid, wid, sigma, 0, dx, dy, rim);
        }
    } else if (on && found >= 0) { // back as it was
        SLSSetWindowShadowAndRimParameters(cid, wid, shadows[found].sigma, shadows[found].density, shadows[found].dx, shadows[found].dy, shadows[found].rim);
        shadows[found].wid = 0;
    } else if (on) { // turned off by a payload injected before (Dock restarted): the default shadow
        float sigma, density;
        int dx, dy, rim;
        if (SLSGetWindowShadowAndRimParameters(cid, wid, &sigma, &density, &dx, &dy, &rim) == kCGErrorSuccess && density == 0)
            SLSSetWindowShadowAndRimParameters(cid, wid, 32.94f, 0.7f, 0, 18, rim);
    }
    pthread_mutex_unlock(&shadow_lock);
    return reply;
}

// track <wid> <ms> <mode> <channels> <n> <samples...>, see the protocol at the top
static const char *start_track(uint32_t wid, char **save)
{
    double head[4];
    for (int i = 0; i < 4; i++) {
        char *tok = strtok_r(NULL, " \n", save);
        if (!tok) return "err bad argument count\n";
        head[i] = strtod(tok, NULL);
    }
    // checked as doubles: casting an out of range double to int is undefined
    if (!(head[0] > 0 && head[0] < 60000) || !(head[1] >= TRACK_ENTER && head[1] <= TRACK_HOLD)
        || !(head[2] >= 1 && head[2] <= 7) || !(head[3] >= 2 && head[3] <= MAX_TRACK_SAMPLES)) {
        return "err bad track header\n";
    }
    double ms = head[0];
    int mode = (int) head[1], channels = (int) head[2], n = (int) head[3];
    float *samples = malloc(sizeof(float) * 6 * (size_t) n);
    if (!samples) return "err oom\n";
    for (int i = 0; i < 6 * n; i++) {
        char *tok = strtok_r(NULL, " \n", save);
        if (!tok) { free(samples); return "err bad argument count\n"; }
        samples[i] = strtof(tok, NULL);
        if (!isfinite(samples[i])) { free(samples); return "err bad sample\n"; }
    }
    if (strtok_r(NULL, " \n", save)) { free(samples); return "err bad argument count\n"; }
    const float *end = samples + 6 * (n - 1);
    if (mode == TRACK_ENTER && (end[2] < 1 || end[3] < 1)) { free(samples); return "err bad end rect\n"; }
    // the track owns what it drives: the window's other animations of it stop
    if (channels & TRACK_FRAME) cancel_anim(ANIM_FRAME, wid);
    if (channels & TRACK_ALPHA) cancel_anim(ANIM_ALPHA, wid);
    if (channels & TRACK_BRIGHTNESS) cancel_anim(ANIM_DIM, wid);
    const char *reply = add_anim((struct anim) {
        .kind = ANIM_TRACK, .wid = wid, .ms = ms, .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1,
        .samples = samples, .nsamples = n, .mode = mode, .channels = channels,
    });
    if (strcmp(reply, "ok\n") != 0) free(samples); // not in the table
    return reply;
}

static const char *handle(char *line)
{
    char *save = NULL;
    char *cmd = strtok_r(line, " \n", &save);
    if (!cmd) return "err empty\n";
    if (strcmp(cmd, "ping") == 0) return "ok fade close layer modal dim vsync batch blur shadow track\n";

    char *wid_str = strtok_r(NULL, " \n", &save);
    if (!wid_str) return "err missing wid\n";
    uint32_t wid = (uint32_t) strtoul(wid_str, NULL, 10);
    if (strcmp(cmd, "track") == 0) return start_track(wid, &save); // more numbers than args[] holds

    double args[16];
    int argc = 0;
    for (char *tok; argc < 16 && (tok = strtok_r(NULL, " \n", &save));) args[argc++] = strtod(tok, NULL);

    if (strcmp(cmd, "fade") == 0) {
        return argc == 6 || argc == 7 ? start_fade(wid, args, argc) : "err bad argument count\n";
    }
    if (strcmp(cmd, "dim") == 0) {
        return argc == 1 || argc == 7 ? start_dim(wid, args, argc) : "err bad argument count\n";
    }
    if (strcmp(cmd, "animate") == 0) {
        return argc == 9 || argc == 13 || argc == 14 ? start_animation(wid, args, argc) : "err bad argument count\n";
    }
    if (strcmp(cmd, "untransform") == 0 && argc == 0) {
        cancel_anim(ANIM_FRAME, wid); // stops a running animation
        strip_track(wid, TRACK_FRAME);
        CGRect real;
        if (SLSGetWindowBounds(SLSMainConnectionID(), wid, &real) != kCGErrorSuccess) return "err no window\n";
        SLSSetWindowTransform(SLSMainConnectionID(), wid, CGAffineTransformMakeTranslation(-real.origin.x, -real.origin.y));
        return "ok\n";
    }

    if (strcmp(cmd, "blur") == 0 && argc == 1) {
        if (args[0] < 0 || args[0] > 100) return "err bad radius\n";
        return SLSSetWindowBackgroundBlurRadius(SLSMainConnectionID(), wid, (uint32_t) args[0]) == kCGErrorSuccess ? "ok\n" : "err no window\n";
    }
    if (strcmp(cmd, "shadow") == 0 && argc == 1) return set_shadow(wid, args[0] != 0);

    if (strcmp(cmd, "layer") == 0 && argc == 1) {
        // layer <wid> 1|2|0: floating window level (above normal windows, like
        // `yabai -m window --layer above`), modal panel level (system prompts, above
        // floating windows) or back to normal. Dock's universal connection may change
        // the level of any app's window.
        int level = CGWindowLevelForKey(args[0] == 2 ? kCGModalPanelWindowLevelKey
                                        : args[0] != 0 ? kCGFloatingWindowLevelKey : kCGNormalWindowLevelKey);
        return SLSSetWindowLevel(SLSMainConnectionID(), wid, level) == kCGErrorSuccess ? "ok\n" : "err no window\n";
    }

    int cid = SLSMainConnectionID();
    CFTypeRef t = SLSTransactionCreate(cid);
    if (!t) return "err transaction\n";

    const char *reply = "ok\n";
    if (strcmp(cmd, "corner") == 0 && argc == 1) {
        SLSTransactionSetWindowCornerRadius(t, wid, args[0]);
    } else if (strcmp(cmd, "uncorner") == 0 && argc == 0) {
        SLSTransactionClearWindowCornerRadius(t, wid);
    } else if (strcmp(cmd, "alpha") == 0 && argc == 1) {
        cancel_anim(ANIM_ALPHA, wid); // stops a running fade
        strip_track(wid, TRACK_ALPHA);
        SLSTransactionSetWindowAlpha(t, wid, (float) args[0]);
    } else {
        reply = "err bad command or argument count\n";
    }
    SLSTransactionCommit(t, 1);
    CFRelease(t);
    return reply;
}

static void *serve(void *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strlcpy(addr.sun_path, path, sizeof(addr.sun_path));
    unlink(addr.sun_path);
    if (fd < 0 || bind(fd, (struct sockaddr *) &addr, sizeof(addr)) != 0 || listen(fd, 16) != 0) {
        fprintf(stderr, "skyland-sa: cannot listen on %s\n", addr.sun_path);
        return NULL;
    }
    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) continue;
        int on = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on)); // a client gone early must not kill Dock
        // one or more commands, one per line, one reply per line, until the client
        // closes its side (an older app sends one line and waits for its reply).
        // static: one client at a time, and a track line is up to ~11 KB
        static char buf[32768];
        size_t len = 0;
        ssize_t n;
        while ((n = read(client, buf + len, sizeof(buf) - 1 - len)) > 0) {
            len += (size_t) n;
            char *line = buf, *nl;
            while ((nl = memchr(line, '\n', (size_t) (buf + len - line)))) {
                *nl = 0;
                const char *reply = handle(line);
                write(client, reply, strlen(reply));
                line = nl + 1;
            }
            len = (size_t) (buf + len - line);
            memmove(buf, line, len);
            if (len == sizeof(buf) - 1) len = 0; // a line too long: dropped
        }
        close(client);
    }
}

#ifndef SKYLAND_PAYLOAD_TEST
__attribute__((constructor))
#endif
static void load(void)
{
    link_queue = dispatch_queue_create("skyland-sa display link", DISPATCH_QUEUE_SERIAL);
    CVDisplayLinkCreateWithActiveCGDisplays(&display_link);
    CVDisplayLinkSetOutputCallback(display_link, step, NULL);
    static char path[104];
    // Dock runs as the logged-in user, so $USER matches the client side
    const char *user = getenv("USER");
    snprintf(path, sizeof(path), "/tmp/skyland-sa_%s.socket", user ? user : "unknown");
    pthread_t thread;
    pthread_create(&thread, NULL, serve, path);
    pthread_detach(thread);
}
