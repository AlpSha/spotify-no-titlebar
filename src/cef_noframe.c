/*
 * cef_noframe — kill Spotify's white CSD title bar on Wayland tiling WMs.
 *
 * Recent Spotify builds create their main window through CEF's Views API,
 * cef_window_create_top_level(cef_window_delegate_t*). On compositors that
 * don't hand the client server-side decorations (niri, Sway, Hyprland, ...),
 * CEF falls back to drawing its own generic, unthemed "Spotify Premium"
 * title bar. It is NOT a GTK CSD, NOT in the web (xpui) DOM, and NOT
 * controlled by any --ozone/Wayland/X11 flag — so nothing in userland
 * (Spicetify, gtk3-nocsd, GTK_CSD=0, theme tweaks) can remove it.
 *
 * This LD_PRELOAD shim interposes the *stable, exported* CEF C API call
 * and rewrites two callbacks in the cef_window_delegate_t the app passes:
 *
 *     is_frameless()                -> return 1   (CEF draws no frame)
 *     with_standard_window_buttons() -> return 0  (no min/max/close overlay)
 *
 * before forwarding to the real libcef symbol. Spotify already ships its own
 * draggable region (.body-drag-top), so a frameless window behaves correctly.
 *
 * ---- Struct offsets ------------------------------------------------------
 * cef_window_delegate_t embeds (flattened, x86-64, 8-byte pointers):
 *
 *   cef_base_ref_counted_t      40  (size_t size + 4 fn ptrs)
 *   CefViewDelegate   11 methods +88
 *   CefPanelDelegate   0 methods  +0
 *   CefWindowDelegate: is_frameless is method #11 (10 before it) +80
 *     => is_frameless                @ 208
 *     => with_standard_window_buttons @ 216
 *
 * Defaults below are for CEF branch 7559 (chromium-144.0.7559), which is
 * what Spotify shipped when this was written. If a Spotify update bumps the
 * CEF major version the layout can shift; override at runtime without
 * recompiling via the env vars below, or recompute (see README).
 *
 * Runtime env vars:
 *   CEF_NOFRAME_OFFSET=<n>       override is_frameless byte offset
 *   CEF_NOFRAME_BTNS_OFFSET=<n>  override with_standard_window_buttons offset
 *   CEF_NOFRAME_DEBUG=1          log what it does to stderr
 *   CEF_NOFRAME_DISABLE=1        passthrough, patch nothing (A/B testing)
 *
 * License: MIT.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#define DEFAULT_OFF_IS_FRAMELESS   208
#define DEFAULT_OFF_WITH_STD_BTNS  216

typedef int (*cb_fn)(void *self, void *window);

static int force_frameless(void *self, void *window)  { (void)self; (void)window; return 1; }
static int force_no_buttons(void *self, void *window) { (void)self; (void)window; return 0; }

static long env_long(const char *name, long fallback) {
    const char *v = getenv(name);
    if (!v || !*v) return fallback;
    char *end = NULL;
    long n = strtol(v, &end, 0);
    return (end && *end == '\0') ? n : fallback;
}

void *cef_window_create_top_level(void *delegate) {
    static void *(*real)(void *) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "cef_window_create_top_level");

    int debug = getenv("CEF_NOFRAME_DEBUG") != NULL;

    if (delegate && getenv("CEF_NOFRAME_DISABLE") == NULL) {
        size_t sz = *(size_t *)delegate;          /* cef_base_ref_counted_t.size */
        long off_fl  = env_long("CEF_NOFRAME_OFFSET",      DEFAULT_OFF_IS_FRAMELESS);
        long off_btn = env_long("CEF_NOFRAME_BTNS_OFFSET", DEFAULT_OFF_WITH_STD_BTNS);
        long need = (off_fl > off_btn ? off_fl : off_btn) + (long)sizeof(void *);

        if ((long)sz >= need && off_fl > 0) {
            *(cb_fn *)((char *)delegate + off_fl)  = force_frameless;
            if (off_btn > 0)
                *(cb_fn *)((char *)delegate + off_btn) = force_no_buttons;
            if (debug)
                fprintf(stderr,
                    "[cef-noframe] frameless forced (delegate size=%zu, "
                    "is_frameless@%ld, buttons@%ld)\n", sz, off_fl, off_btn);
        } else if (debug) {
            fprintf(stderr,
                "[cef-noframe] SKIP: delegate size=%zu < required %ld "
                "(wrong offsets for this CEF version?)\n", sz, need);
        }
    } else if (debug) {
        fprintf(stderr, "[cef-noframe] passthrough (disabled or null delegate)\n");
    }
    return real(delegate);
}
