// Skyland scripting addition payload, injected into Dock.app by loader.m.
// Dock owns the universal SkyLight connection, so window changes issued from
// here apply to every app's windows (from any other process they are ignored).
//
// Protocol: one text line per connection on /tmp/skyland-sa_$USER.socket,
// reply "ok\n" or "err <reason>\n".
//   ping
//   corner <wid> <radius>
//   uncorner <wid>                     (back to the system radius)
//   alpha <wid> <alpha> <duration>
//   transform <wid> <m11> ... <m44>    (CATransform3D, 16 values, row major)
//
// Signatures from REA decompilation of SkyLight on macOS 15.6.1 (24G90),
// see vault note "SkyLight private API recon".

#include <CoreFoundation/CoreFoundation.h>
#include <QuartzCore/QuartzCore.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

extern int SLSMainConnectionID(void);
extern CFTypeRef SLSTransactionCreate(int cid);
extern int SLSTransactionCommit(CFTypeRef t, int sync);
extern void SLSTransactionSetWindowCornerRadius(CFTypeRef t, uint32_t wid, double radius);
extern void SLSTransactionClearWindowCornerRadius(CFTypeRef t, uint32_t wid);
extern void SLSTransactionSetWindowAlphaAnimated(CFTypeRef t, uint32_t wid, float alpha, float duration);
extern void SLSTransactionSetWindowTransform3D(CFTypeRef t, uint32_t wid, CATransform3D *transform);

static const char *handle(char *line)
{
    char *save = NULL;
    char *cmd = strtok_r(line, " \n", &save);
    if (!cmd) return "err empty\n";
    if (strcmp(cmd, "ping") == 0) return "ok\n";

    char *wid_str = strtok_r(NULL, " \n", &save);
    if (!wid_str) return "err missing wid\n";
    uint32_t wid = (uint32_t) strtoul(wid_str, NULL, 10);

    double args[16];
    int argc = 0;
    for (char *tok; argc < 16 && (tok = strtok_r(NULL, " \n", &save));) args[argc++] = strtod(tok, NULL);

    int cid = SLSMainConnectionID();
    CFTypeRef t = SLSTransactionCreate(cid);
    if (!t) return "err transaction\n";

    const char *reply = "ok\n";
    if (strcmp(cmd, "corner") == 0 && argc == 1) {
        SLSTransactionSetWindowCornerRadius(t, wid, args[0]);
    } else if (strcmp(cmd, "uncorner") == 0 && argc == 0) {
        SLSTransactionClearWindowCornerRadius(t, wid);
    } else if (strcmp(cmd, "alpha") == 0 && argc == 2) {
        SLSTransactionSetWindowAlphaAnimated(t, wid, (float) args[0], (float) args[1]);
    } else if (strcmp(cmd, "transform") == 0 && argc == 16) {
        CATransform3D m;
        memcpy(&m, args, sizeof(m)); // CATransform3D is 16 CGFloat (double) fields
        SLSTransactionSetWindowTransform3D(t, wid, &m);
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
