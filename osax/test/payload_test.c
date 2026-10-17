// Unit test of the payload's animation table and `track` command, without macOS:
// payload.m is included with stand-in SDK headers (osax/test/stubs), SkyLight is
// replaced by functions that record what the payload sets, and the clock is fake.
//
//   clang -fblocks -g -fsanitize=address,undefined -I osax/test/stubs osax/test/payload_test.c -o .build/payload_test -lm -lpthread
//   .build/payload_test
// (on macOS: xcrun clang, same flags)
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef __APPLE__
#define SO_NOSIGPIPE 0x1022 // Linux has no such option; serve() is not run here
// block literals reference these runtime symbols; dispatch_async calls blocks directly
void *_NSConcreteGlobalBlock[32];
void *_NSConcreteStackBlock[32];
#endif

static double fake_now;
static int fake_clock_gettime(clockid_t clock, struct timespec *ts)
{
    (void) clock;
    ts->tv_sec = (time_t) (fake_now / 1000);
    ts->tv_nsec = (long) ((fake_now - ts->tv_sec * 1000.0) * 1e6);
    return 0;
}
#define clock_gettime fake_clock_gettime
#define SKYLAND_PAYLOAD_TEST
#include "../payload.m"

// SkyLight, recorded per window

struct win {
    uint32_t wid;
    int exists;
    CGRect bounds;
    CGAffineTransform transform;
    float alpha, brightness;
    int transforms, alphas, brightnesses; // number of times each was set
};
static struct win wins[4];

static struct win *win(uint32_t wid)
{
    for (int i = 0; i < 4; i++) if (wins[i].wid == wid) return &wins[i];
    fprintf(stderr, "no window %u\n", wid);
    abort();
}

static void add_window(int i, uint32_t wid, CGRect bounds)
{
    wins[i] = (struct win) { .wid = wid, .exists = 1, .bounds = bounds, .alpha = 1,
                             .transform = CGAffineTransformMakeTranslation(-bounds.origin.x, -bounds.origin.y) };
}

int SLSMainConnectionID(void) { return 1; }
CFTypeRef SLSTransactionCreate(int cid) { (void) cid; return malloc(1); }
int SLSTransactionCommit(CFTypeRef t, int sync) { (void) t; (void) sync; return 0; }
void CFRelease(CFTypeRef cf) { free((void *) cf); }
void SLSTransactionSetWindowCornerRadius(CFTypeRef t, uint32_t wid, double radius) { (void) t; (void) wid; (void) radius; }
void SLSTransactionClearWindowCornerRadius(CFTypeRef t, uint32_t wid) { (void) t; (void) wid; }

static void record_alpha(uint32_t wid, float alpha) { win(wid)->alpha = alpha; win(wid)->alphas++; }
static void record_transform(uint32_t wid, CGAffineTransform t) { win(wid)->transform = t; win(wid)->transforms++; }
static void record_brightness(uint32_t wid, float b) { win(wid)->brightness = b; win(wid)->brightnesses++; }

void SLSTransactionSetWindowAlpha(CFTypeRef t, uint32_t wid, float alpha) { (void) t; record_alpha(wid, alpha); }
CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha) { (void) cid; record_alpha(wid, alpha); return 0; }
CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha) { (void) cid; *alpha = win(wid)->alpha; return 0; }
CGError SLSSetWindowLevel(int cid, uint32_t wid, int level) { (void) cid; (void) wid; (void) level; return 0; }
// blur / shadow (#25): not recorded, the tests don't look at them
CGError SLSSetWindowBackgroundBlurRadius(int cid, uint32_t wid, uint32_t radius) { (void) cid; (void) wid; (void) radius; return 0; }
CGError SLSGetWindowShadowAndRimParameters(int cid, uint32_t wid, float *sigma, float *density, int *dx, int *dy, int *rim)
{
    (void) cid; (void) wid;
    *sigma = 32.94f; *density = 0.7f; *dx = 0; *dy = 18; *rim = 0;
    return 0;
}
CGError SLSSetWindowShadowAndRimParameters(int cid, uint32_t wid, float sigma, float density, int dx, int dy, int rim)
{
    (void) cid; (void) wid; (void) sigma; (void) density; (void) dx; (void) dy; (void) rim;
    return 0;
}

CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame)
{
    (void) cid;
    struct win *w = win(wid);
    if (!w->exists) return kCGErrorFailure;
    *frame = w->bounds;
    return kCGErrorSuccess;
}

CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t) { (void) cid; record_transform(wid, t); return 0; }
void SLSTransactionSetWindowTransform(CFTypeRef t, uint32_t wid, int unknown1, int unknown2, CGAffineTransform transform)
{
    (void) t; (void) unknown1; (void) unknown2;
    record_transform(wid, transform);
}

CGError SLSSetWindowListBrightness(int cid, uint32_t *wids, float *brightness, int count)
{
    (void) cid;
    for (int i = 0; i < count; i++) record_brightness(wids[i], brightness[i]);
    return 0;
}
void SLSTransactionSetWindowBrightness(CFTypeRef t, uint32_t wid, float brightness) { (void) t; record_brightness(wid, brightness); }

// CoreVideo and dispatch

static int link_starts, link_stops;
CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *link) { *link = NULL; return kCVReturnSuccess; }
CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link, CVDisplayLinkOutputCallback callback, void *context)
{
    (void) link; (void) callback; (void) context;
    return kCVReturnSuccess;
}
CVReturn CVDisplayLinkStart(CVDisplayLinkRef link) { (void) link; link_starts++; return kCVReturnSuccess; }
CVReturn CVDisplayLinkStop(CVDisplayLinkRef link) { (void) link; link_stops++; return kCVReturnSuccess; }

static struct dispatch_queue_s { int unused; } the_queue;
dispatch_queue_t dispatch_queue_create(const char *label, void *attr) { (void) label; (void) attr; return &the_queue; }
void dispatch_async(dispatch_queue_t queue, dispatch_block_t block) { (void) queue; block(); }

// helpers

static const char *command(const char *line)
{
    static char buf[32768];
    snprintf(buf, sizeof(buf), "%s", line);
    return handle(buf);
}

static void frame_at(double ms)
{
    fake_now = ms;
    step(NULL, NULL, NULL, 0, NULL, NULL);
}

static int running(void)
{
    int count = 0;
    for (int i = 0; i < MAX_ANIMS; i++) count += anims[i].used;
    return count;
}

static int near(double a, double b) { return fabs(a - b) < 1e-3; }

// The rect a window is shown at, from its transform (see transform_showing).
static CGRect visual(uint32_t wid)
{
    struct win *w = win(wid);
    CGAffineTransform t = w->transform;
    return CGRectMake(-t.tx / t.a, -t.ty / t.d, w->bounds.size.width / t.a, w->bounds.size.height / t.d);
}

static int rect_is(CGRect r, double x, double y, double w, double h)
{
    return near(r.origin.x, x) && near(r.origin.y, y) && near(r.size.width, w) && near(r.size.height, h);
}

static int at_rest(uint32_t wid)
{
    struct win *w = win(wid);
    return near(w->transform.a, 1) && near(w->transform.d, 1) && near(w->transform.tx, -w->bounds.origin.x)
        && near(w->transform.ty, -w->bounds.origin.y);
}

// popin 50% of (100, 100, 400, 300): 3 samples, alpha 0 -> 1, brightness 0.8 -> 0
#define POPIN_TRACK(mode, channels) \
    "track 7 100 " #mode " " #channels " 3 200 175 200 150 0 0.8  150 137.5 300 225 0.5 0.4  100 100 400 300 1 0"

static void test_ping(void)
{
    assert(strstr(command("ping"), " track") != NULL);
}

static void test_enter_track(void)
{
    add_window(0, 7, CGRectMake(100, 100, 400, 300));
    fake_now = 1000;
    assert(strcmp(command(POPIN_TRACK(0, 7)), "ok\n") == 0);
    assert(running() == 1);
    frame_at(1000);
    assert(rect_is(visual(7), 200, 175, 200, 150));
    assert(near(win(7)->alpha, 0) && near(win(7)->brightness, 0.8));
    frame_at(1025); // a quarter: half way from the first sample to the second
    assert(rect_is(visual(7), 175, 156.25, 250, 187.5));
    assert(near(win(7)->alpha, 0.25) && near(win(7)->brightness, 0.6));
    frame_at(1075);
    assert(rect_is(visual(7), 125, 118.75, 350, 262.5));
    frame_at(1100); // the end: back to the real frame, the last alpha and brightness
    assert(at_rest(7));
    assert(near(win(7)->alpha, 1) && near(win(7)->brightness, 0));
    assert(running() == 0);
}

static void test_enter_track_follows_the_real_frame(void)
{
    // the app applied a frame 10% wider and 20 px to the right of the track's last rect
    add_window(0, 7, CGRectMake(120, 100, 440, 300));
    fake_now = 0;
    assert(strcmp(command(POPIN_TRACK(0, 1)), "ok\n") == 0);
    frame_at(0);
    // (200, 175, 200, 150) relative to (100, 100, 400, 300), mapped onto (120, 100, 440, 300)
    assert(rect_is(visual(7), 120 + 100 * 1.1, 175, 220, 150));
    frame_at(100);
    assert(at_rest(7));
}

static void test_leave_and_hold_tracks(void)
{
    add_window(0, 7, CGRectMake(100, 100, 400, 300));
    // leave: screen rects as given, back to the real frame at the end
    fake_now = 0;
    assert(strcmp(command("track 7 100 1 1 2 100 100 400 300 1 0  900 100 400 300 0 0"), "ok\n") == 0);
    frame_at(50);
    assert(rect_is(visual(7), 500, 100, 400, 300));
    frame_at(100);
    assert(at_rest(7));
    // hold: stays at the last rect (a window being closed)
    fake_now = 200;
    assert(strcmp(command("track 7 100 2 3 2 100 100 400 300 1 0  290 237.5 20 25 0 0"), "ok\n") == 0);
    frame_at(300);
    assert(rect_is(visual(7), 290, 237.5, 20, 25));
    assert(near(win(7)->alpha, 0));
    assert(running() == 0);
}

static void test_other_commands_take_channels_over(void)
{
    add_window(0, 7, CGRectMake(100, 100, 400, 300));
    fake_now = 0;
    assert(strcmp(command(POPIN_TRACK(0, 7)), "ok\n") == 0);
    frame_at(10);
    // alpha: the track keeps the frame and the brightness
    assert(strcmp(command("alpha 7 0.9"), "ok\n") == 0);
    int alphas = win(7)->alphas, transforms = win(7)->transforms;
    frame_at(20);
    assert(win(7)->alphas == alphas && win(7)->transforms == transforms + 1);
    assert(near(win(7)->alpha, 0.9));
    // dim: the brightness too
    assert(strcmp(command("dim 7 0"), "ok\n") == 0);
    int brightnesses = win(7)->brightnesses;
    frame_at(30);
    assert(win(7)->brightnesses == brightnesses);
    assert(running() == 1);
    // untransform: nothing left, the track is gone
    assert(strcmp(command("untransform 7"), "ok\n") == 0);
    assert(running() == 0);
    assert(at_rest(7));

    // animate takes the frame over, the track goes on with the alpha
    fake_now = 1000;
    assert(strcmp(command(POPIN_TRACK(0, 3)), "ok\n") == 0);
    assert(strcmp(command("animate 7 0 0 400 300 100 0 0 1 1"), "ok\n") == 0);
    assert(running() == 2);
    frame_at(1050);
    assert(near(win(7)->alpha, 0.5));
    frame_at(1100);
    assert(running() == 0);

    // a track takes over a running fade, dim and frame animation of its window
    fake_now = 2000;
    assert(strcmp(command("fade 7 0.5 100 0 0 1 1"), "ok\n") == 0);
    assert(strcmp(command("dim 7 0.5 100 0 0 1 1 0"), "ok\n") == 0);
    assert(strcmp(command("animate 7 0 0 400 300 100 0 0 1 1"), "ok\n") == 0);
    assert(running() == 3);
    assert(strcmp(command(POPIN_TRACK(0, 7)), "ok\n") == 0);
    assert(running() == 1);
    // and a new track replaces the running one (its samples are freed: no leak)
    assert(strcmp(command(POPIN_TRACK(0, 1)), "ok\n") == 0);
    assert(running() == 1);
    frame_at(2100);
    assert(running() == 0);
}

static void test_window_gone(void)
{
    add_window(0, 7, CGRectMake(100, 100, 400, 300));
    fake_now = 0;
    assert(strcmp(command(POPIN_TRACK(0, 7)), "ok\n") == 0);
    win(7)->exists = 0;
    frame_at(10);
    assert(running() == 0);
}

static void test_bad_tracks(void)
{
    add_window(0, 7, CGRectMake(100, 100, 400, 300));
    const char *bad[] = {
        "track 7",
        "track 7 100 0 1",
        "track 7 0 0 1 2 0 0 1 1 1 0  0 0 1 1 1 0",       // no duration
        "track 7 100 3 1 2 0 0 1 1 1 0  0 0 1 1 1 0",     // no such mode
        "track 7 100 0 0 2 0 0 1 1 1 0  0 0 1 1 1 0",     // no channel
        "track 7 100 0 8 2 0 0 1 1 1 0  0 0 1 1 1 0",
        "track 7 100 0 1 1 0 0 1 1 1 0",                   // one sample
        "track 7 100 0 1 241 0 0 1 1 1 0",                 // too many
        "track 7 100 0 1 1e30 0 0 1 1 1 0",
        "track 7 100 0 1 2 0 0 1 1 1 0  0 0 1 1 1",       // a number missing
        "track 7 100 0 1 2 0 0 1 1 1 0  0 0 1 1 1 0 9",   // one too many
        "track 7 100 0 1 2 0 0 1 1 1 0  0 0 0 1 1 0",     // enter ends on an empty rect
        "track 7 100 0 1 2 0 0 1 1 1 0  0 0 1 1 nan 0",
        "track 7 100 0 1 2 0 0 1 1 1 0  0 0 1 1 inf 0",
    };
    for (size_t i = 0; i < sizeof(bad) / sizeof(*bad); i++) {
        const char *reply = command(bad[i]);
        if (strncmp(reply, "err", 3) != 0) { fprintf(stderr, "accepted: %s\n", bad[i]); abort(); }
    }
    assert(running() == 0);
}

static void test_longest_track(void)
{
    add_window(0, 7, CGRectMake(100, 100, 400, 300));
    static char line[32768];
    int len = snprintf(line, sizeof(line), "track 7 4000 0 7 %d", MAX_TRACK_SAMPLES);
    for (int i = 0; i < MAX_TRACK_SAMPLES; i++) {
        len += snprintf(line + len, sizeof(line) - (size_t) len, " %.1f %.1f %.1f %.1f %.3f %.3f",
                        1234.5 + i, 1234.5, 2345.6, 1345.6, 0.875, -0.125);
    }
    assert(len < 16384); // fits the payload's line buffer with room to spare
    fake_now = 0;
    assert(strcmp(command(line), "ok\n") == 0);
    for (double t = 0; t <= 4000; t += 8.3) frame_at(t);
    frame_at(4000);
    assert(running() == 0);
}

// random commands and frames: the address and undefined behavior sanitizers watch
static void test_random(void)
{
    add_window(0, 1, CGRectMake(0, 0, 800, 600));
    add_window(1, 2, CGRectMake(800, 0, 800, 600));
    add_window(2, 3, CGRectMake(0, 600, 800, 600));
    srand(42);
    static char line[32768];
    fake_now = 0;
    for (int round = 0; round < 20000; round++) {
        uint32_t wid = 1 + (uint32_t) (rand() % 3);
        switch (rand() % 9) {
            case 0: case 1: case 2: {
                int n = 2 + rand() % 40;
                int len = snprintf(line, sizeof(line), "track %u %d %d %d %d", wid, 1 + rand() % 900, rand() % 3,
                                   1 + rand() % 7, n);
                for (int i = 0; i < n; i++) {
                    len += snprintf(line + len, sizeof(line) - (size_t) len, " %d %d %d %d %.2f %.2f", rand() % 2000 - 500,
                                    rand() % 1500 - 300, rand() % 900, 1 + rand() % 700, rand() % 120 / 100.0 - 0.1,
                                    rand() % 240 / 100.0 - 1.2);
                }
                command(line);
                break;
            }
            case 3: snprintf(line, sizeof(line), "fade %u %.2f %d 0 0 1 1", wid, rand() % 100 / 100.0, 1 + rand() % 500); command(line); break;
            case 4: snprintf(line, sizeof(line), "dim %u %.2f", wid, rand() % 100 / 100.0); command(line); break;
            case 5: snprintf(line, sizeof(line), "animate %u 0 0 300 200 %d 0 0 1 1", wid, 1 + rand() % 500); command(line); break;
            case 6: snprintf(line, sizeof(line), "untransform %u", wid); command(line); break;
            case 7: win(wid)->exists = rand() % 10 != 0; break;
            default: frame_at(fake_now + rand() % 20); break;
        }
    }
    for (int i = 0; i < 3; i++) wins[i].exists = 1;
    frame_at(fake_now + 100000);
    assert(running() == 0);
}

int main(void)
{
    test_ping();
    test_enter_track();
    test_enter_track_follows_the_real_frame();
    test_leave_and_hold_tracks();
    test_other_commands_take_channels_over();
    test_window_gone();
    test_bad_tracks();
    test_longest_track();
    test_random();
    assert(link_starts > 0 && link_stops > 0);
    puts("payload ok");
    return 0;
}
