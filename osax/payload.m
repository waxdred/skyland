// Skyland payload, injected into Dock.app by loader.m.
// Dock owns the universal SkyLight connection, so window changes issued from
// here apply to every app's windows (from any other process they are ignored).
//
// Protocol: one text line per connection on /tmp/skyland-sa_$USER.socket,
// reply "ok\n" or "err <reason>\n".
//   ping                               (replies "ok fade": capabilities, old payloads reply "ok")
//   corner <wid> <radius>
//   uncorner <wid>                     (back to the system radius)
//   alpha <wid> <alpha>                (cancels a running fade)
//   fade <wid> <alpha> <ms> <x1> <y1> <x2> <y2> [<from>]
//       step the alpha from its current value (or <from>) along the bezier, like yabai's
//       opacity_fade: SLSSetWindowAlpha every 8 ms, no WindowServer fade.
//   animate <wid> <x> <y> <w> <h> <ms> <x1> <y1> <x2> <y2> [<tx> <ty> <tw> <th>]
//       show the window at rect (x,y,w,h) then move it to its real frame over
//       <ms> following the cubic bezier (x1,y1,x2,y2). With a target rect it moves
//       there instead and jumps to its real frame at the end (slide-out of a
//       window being hidden). Stepped here with SLSSetWindowTransform, never with
//       a WindowServer-side animation.
//
// Signatures from REA decompilation of SkyLight on macOS 15.6.1 (24G90),
// see vault note "SkyLight private API recon".

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
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

// Latest animation generation per window: a newer `animate` on the same window
// takes over and the older stepping thread stops without touching it.
// ponytail: fixed table, slot reuse by hash; collisions only cancel early.
// Frame (transform) and alpha animations are tracked separately: a window can
// slide and fade at the same time.
#define ANIM_SLOTS 512
struct anim_table { struct { uint32_t wid; uint64_t gen; } slots[ANIM_SLOTS]; };
static struct anim_table frame_anims, alpha_anims;
static pthread_mutex_t anim_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t anim_counter;

static uint64_t anim_claim(struct anim_table *table, uint32_t wid)
{
    pthread_mutex_lock(&anim_lock);
    uint64_t gen = ++anim_counter;
    table->slots[wid % ANIM_SLOTS].wid = wid;
    table->slots[wid % ANIM_SLOTS].gen = gen;
    pthread_mutex_unlock(&anim_lock);
    return gen;
}

static int anim_current(struct anim_table *table, uint32_t wid, uint64_t gen)
{
    pthread_mutex_lock(&anim_lock);
    int current = table->slots[wid % ANIM_SLOTS].wid == wid && table->slots[wid % ANIM_SLOTS].gen == gen;
    pthread_mutex_unlock(&anim_lock);
    return current;
}

// The window transform maps screen points to window points; at rest it is a
// translation by -origin. Showing a window of real frame `real` at `visual`:
// p -> (p - visual.origin) * real.size / visual.size.
static void show_at(int cid, uint32_t wid, CGRect real, CGRect visual)
{
    CGAffineTransform t = CGAffineTransformConcat(
        CGAffineTransformMakeTranslation(-visual.origin.x, -visual.origin.y),
        CGAffineTransformMakeScale(real.size.width / visual.size.width, real.size.height / visual.size.height));
    SLSSetWindowTransform(cid, wid, t);
}

struct animation { uint32_t wid; uint64_t gen; CGRect from, to; int has_to; double ms, x1, y1, x2, y2; };

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

static void *animate(void *arg)
{
    struct animation a = *(struct animation *) arg;
    free(arg);
    int cid = SLSMainConnectionID();
    double start = now_ms();
    CGRect real;
    for (;;) {
        if (!anim_current(&frame_anims, a.wid, a.gen)) return NULL; // a newer animation owns the window
        if (SLSGetWindowBounds(cid, a.wid, &real) != kCGErrorSuccess) return NULL; // window gone
        double x = (now_ms() - start) / a.ms;
        if (x >= 1) break;
        // without a target the real frame is read every frame: the app may apply it late
        CGRect to = a.has_to ? a.to : real;
        double p = bezier_ease(x, a.x1, a.y1, a.x2, a.y2);
        CGRect v = CGRectMake(
            a.from.origin.x + (to.origin.x - a.from.origin.x) * p,
            a.from.origin.y + (to.origin.y - a.from.origin.y) * p,
            a.from.size.width + (to.size.width - a.from.size.width) * p,
            a.from.size.height + (to.size.height - a.from.size.height) * p);
        if (v.size.width >= 1 && v.size.height >= 1) show_at(cid, a.wid, real, v);
        usleep(8000); // ~120 Hz
    }
    SLSSetWindowTransform(cid, a.wid, CGAffineTransformMakeTranslation(-real.origin.x, -real.origin.y));
    return NULL;
}

struct fade { uint32_t wid; uint64_t gen; float to, from; int has_from; double ms, x1, y1, x2, y2; };

static void *fade(void *arg)
{
    struct fade f = *(struct fade *) arg;
    free(arg);
    int cid = SLSMainConnectionID();
    float from = f.from;
    if (!f.has_from) SLSGetWindowAlpha(cid, f.wid, &from);
    double start = now_ms();
    CGRect bounds;
    for (;;) {
        if (!anim_current(&alpha_anims, f.wid, f.gen)) return NULL; // a newer alpha owns the window
        if (SLSGetWindowBounds(cid, f.wid, &bounds) != kCGErrorSuccess) return NULL; // window gone
        double x = (now_ms() - start) / f.ms;
        if (x >= 1) break;
        SLSSetWindowAlpha(cid, f.wid, from + (f.to - from) * (float) bezier_ease(x, f.x1, f.y1, f.x2, f.y2));
        usleep(8000);
    }
    SLSSetWindowAlpha(cid, f.wid, f.to);
    return NULL;
}

static const char *start_fade(uint32_t wid, double *args, int argc)
{
    if (args[0] < 0 || args[0] > 1 || args[1] <= 0) return "err bad alpha or duration\n";
    if (argc == 7 && (args[6] < 0 || args[6] > 1)) return "err bad start alpha\n";
    struct fade *f = malloc(sizeof(*f));
    if (!f) return "err oom\n";
    *f = (struct fade) {
        .wid = wid, .gen = anim_claim(&alpha_anims, wid), .to = (float) args[0],
        .ms = args[1], .x1 = args[2], .y1 = args[3], .x2 = args[4], .y2 = args[5],
        .has_from = argc == 7, .from = argc == 7 ? (float) args[6] : 1,
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, fade, f) != 0) { free(f); return "err thread\n"; }
    pthread_detach(thread);
    return "ok\n";
}

static const char *start_animation(uint32_t wid, double *args, int argc)
{
    if (args[2] < 1 || args[3] < 1 || args[4] <= 0) return "err bad rect or duration\n";
    if (argc == 13 && (args[11] < 1 || args[12] < 1)) return "err bad target rect\n";
    struct animation *a = malloc(sizeof(*a));
    if (!a) return "err oom\n";
    *a = (struct animation) {
        .wid = wid, .gen = anim_claim(&frame_anims, wid), .from = CGRectMake(args[0], args[1], args[2], args[3]),
        .ms = args[4], .x1 = args[5], .y1 = args[6], .x2 = args[7], .y2 = args[8],
        .has_to = argc == 13, .to = argc == 13 ? CGRectMake(args[9], args[10], args[11], args[12]) : CGRectZero,
    };
    pthread_t thread;
    if (pthread_create(&thread, NULL, animate, a) != 0) { free(a); return "err thread\n"; }
    pthread_detach(thread);
    return "ok\n";
}

static const char *handle(char *line)
{
    char *save = NULL;
    char *cmd = strtok_r(line, " \n", &save);
    if (!cmd) return "err empty\n";
    if (strcmp(cmd, "ping") == 0) return "ok fade\n";

    char *wid_str = strtok_r(NULL, " \n", &save);
    if (!wid_str) return "err missing wid\n";
    uint32_t wid = (uint32_t) strtoul(wid_str, NULL, 10);

    double args[16];
    int argc = 0;
    for (char *tok; argc < 16 && (tok = strtok_r(NULL, " \n", &save));) args[argc++] = strtod(tok, NULL);

    if (strcmp(cmd, "fade") == 0) {
        return argc == 6 || argc == 7 ? start_fade(wid, args, argc) : "err bad argument count\n";
    }
    if (strcmp(cmd, "animate") == 0) {
        return argc == 9 || argc == 13 ? start_animation(wid, args, argc) : "err bad argument count\n";
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
        anim_claim(&alpha_anims, wid); // stops a running fade
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
        char buf[1024] = {0};
        ssize_t n = read(client, buf, sizeof(buf) - 1);
        if (n > 0) {
            const char *reply = handle(buf);
            write(client, reply, strlen(reply));
        }
        close(client);
    }
}

__attribute__((constructor))
static void load(void)
{
    static char path[104];
    // Dock runs as the logged-in user, so $USER matches the client side
    const char *user = getenv("USER");
    snprintf(path, sizeof(path), "/tmp/skyland-sa_%s.socket", user ? user : "unknown");
    pthread_t thread;
    pthread_create(&thread, NULL, serve, path);
    pthread_detach(thread);
}
