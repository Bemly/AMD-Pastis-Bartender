#import "OBKit.h"

#include "obcore.h"   // 套件自包含头(在 ~/.obkit/16.7.19,仓库外;见 tools/getkit.sh)
#include <dlfcn.h>
#include <pthread.h>

// ---- 函数指针(全部经 dlsym 装载,符号名见 kSyms,base64 存放) ----
static void      (*p_init)(void);
static void     *(*p_mgr_new)(void);
static void     *(*p_mgr_by_type_sync)(void *, int, int, void *, void *);
static void     *(*p_mgr_remote_sync)(void *, const char *, void *, void *, void *);
static void     *(*p_mgr_close_sync)(void *, void *, void *);
static void     *(*p_proc_by_name_sync)(void *, const char *, void *, void *, void *);
static const char *(*p_dev_name)(void *);
static unsigned  (*p_proc_pid)(void *);
static void     *(*p_attach_sync)(void *, unsigned, void *, void *, void *);
static void     *(*p_script_new_sync)(void *, const char *, void *, void *, void *);
static void      (*p_script_load_sync)(void *, void *, void *);
static void      (*p_script_unload_sync)(void *, void *, void *);
static void      (*p_script_post)(void *, const char *, void *);
static void      (*p_detach_sync)(void *, void *, void *);

// 符号名 base64 表(与上列指针一一对应;新增 API 时两边同步加)
static const char *kSyms[] = {
    "ZnJpZGFfaW5pdA==",                                             // init
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfbmV3",                             // manager_new
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfZ2V0X2RldmljZV9ieV90eXBlX3N5bmM=", // manager_get_device_by_type_sync
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfYWRkX3JlbW90ZV9kZXZpY2Vfc3luYw==", // manager_add_remote_device_sync
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfY2xvc2Vfc3luYw==",                 // manager_close_sync
    "ZnJpZGFfZGV2aWNlX2dldF9wcm9jZXNzX2J5X25hbWVfc3luYw==",         // device_get_process_by_name_sync
    "ZnJpZGFfZGV2aWNlX2dldF9uYW1l",                                 // device_get_name
    "ZnJpZGFfcHJvY2Vzc19nZXRfcGlk",                                 // process_get_pid
    "ZnJpZGFfZGV2aWNlX2F0dGFjaF9zeW5j",                             // device_attach_sync
    "ZnJpZGFfc2Vzc2lvbl9jcmVhdGVfc2NyaXB0X3N5bmM=",                 // session_create_script_sync
    "ZnJpZGFfc2NyaXB0X2xvYWRfc3luYw==",                             // script_load_sync
    "ZnJpZGFfc2NyaXB0X3VubG9hZF9zeW5j",                             // script_unload_sync
    "ZnJpZGFfc2NyaXB0X3Bvc3Q=",                                     // script_post
    "ZnJpZGFfc2Vzc2lvbl9kZXRhY2hfc3luYw==",                         // session_detach_sync
};

static void *sym_at(size_t i) {
    static const char *T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    char name[128];
    int v = 0, bits = 0, n = 0;
    for (const char *b = kSyms[i]; *b && *b != '='; b++) {
        const char *f = strchr(T, *b);
        if (!f) abort();
        v = (v << 6) | (int)(f - T);
        bits += 6;
        if (bits >= 8) { bits -= 8; name[n++] = (char)((v >> bits) & 0xFF); }
    }
    name[n] = 0;
    void *p = dlsym(RTLD_DEFAULT, name);
    if (!p) {
        fprintf(stderr, "[obkit] dlsym 失败(%zu):-force_load/-export_dynamic 检查\n", i);
        abort();
    }
    return p;
}

static void load_syms(void) {
    p_init               = sym_at(0);
    p_mgr_new            = sym_at(1);
    p_mgr_by_type_sync   = sym_at(2);
    p_mgr_remote_sync    = sym_at(3);
    p_mgr_close_sync     = sym_at(4);
    p_proc_by_name_sync  = sym_at(5);
    p_dev_name           = sym_at(6);
    p_proc_pid           = sym_at(7);
    p_attach_sync        = sym_at(8);
    p_script_new_sync    = sym_at(9);
    p_script_load_sync   = sym_at(10);
    p_script_unload_sync = sym_at(11);
    p_script_post        = sym_at(12);
    p_detach_sync        = sym_at(13);
}

static GMainLoop *g_loop = NULL;
static pthread_mutex_t g_boot_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_boot_cv = PTHREAD_COND_INITIALIZER;
static int g_booted = 0;

static void *boot_main(void *arg) {
    (void)arg;
    load_syms();
    p_init();                                    // 必须先于一切套件 API,且在带主循环的线程
    pthread_mutex_lock(&g_boot_mx);
    g_booted = 1;
    pthread_cond_signal(&g_boot_cv);
    pthread_mutex_unlock(&g_boot_mx);
    g_loop = g_main_loop_new(NULL, TRUE);
    g_main_loop_run(g_loop);                     // 承载 message/detached 信号
    return NULL;
}

void ob_bootstrap(void) {
    pthread_mutex_lock(&g_boot_mx);
    if (g_booted) { pthread_mutex_unlock(&g_boot_mx); return; }
    pthread_t t;
    pthread_create(&t, NULL, boot_main, NULL);
    while (!g_booted) pthread_cond_wait(&g_boot_cv, &g_boot_mx);
    pthread_mutex_unlock(&g_boot_mx);
}

// ---- 小工具 ----
static NSString *ErrOut(GError *e, NSString **outErr) {
    if (!e) return nil;
    NSString *s = [NSString stringWithUTF8String:e->message ?: "?"];
    g_error_free(e);
    if (outErr) *outErr = s;
    return s;
}

static void *mgrOnce(void) {
    static void *mgr = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mgr = p_mgr_new(); });
    return mgr;
}

static void MsgBlockFreeHelper(gpointer ud, GClosure *closure) {
    (void)closure;
    CFBridgingRelease((CFTypeRef)ud);
}

static void msg_trampoline(void *script, const gchar *message, GBytes *data, gpointer ud) {
    void (^block)(NSString *, NSData *) = (__bridge id)ud;
    NSString *json = message ? [NSString stringWithUTF8String:message] : nil;
    NSData *bytes = nil;
    if (data) {
        gsize n = 0;
        gconstpointer p = g_bytes_get_data(data, &n);
        if (p && n) bytes = [NSData dataWithBytes:p length:n];
    }
    block(json, bytes);
}

static void detached_trampoline(void *session, int reason, void *crash, gpointer ud) {
    (void)session; (void)crash;
    void (^block)(int) = (__bridge id)ud;
    block(reason);
}

// ---- API ----
void *ob_manager(void) { ob_bootstrap(); return mgrOnce(); }

void *ob_device_usb(int timeout, NSString **outErr) {
    GError *e = NULL;
    void *d = p_mgr_by_type_sync(mgrOnce(), 2 /*设备类型:USB*/, timeout, NULL, &e);
    ErrOut(e, outErr);
    return d;
}

void *ob_device_remote(NSString *addr, NSString **outErr) {
    GError *e = NULL;
    void *d = p_mgr_remote_sync(mgrOnce(), addr.UTF8String, NULL, NULL, &e);
    ErrOut(e, outErr);
    return d;
}

NSString *ob_device_name(void *dev) {
    if (!dev) return @"";
    const char *n = p_dev_name(dev);
    return n ? @(n) : @"";
}

unsigned ob_pid_by_name(void *dev, NSString *procName, NSString **outErr) {
    GError *e = NULL;
    void *proc = p_proc_by_name_sync(dev, procName.UTF8String, NULL, NULL, &e);
    if (ErrOut(e, outErr)) return 0;
    unsigned pid = p_proc_pid(proc);
    g_object_unref(proc);
    return pid;
}

void *ob_attach(void *dev, unsigned pid, NSString **outErr) {
    GError *e = NULL;
    void *s = p_attach_sync(dev, pid, NULL, NULL, &e);
    ErrOut(e, outErr);
    return s;
}

void ob_on_detached(void *session, void (^block)(int)) {
    g_signal_connect_data(session, "detached", G_CALLBACK(detached_trampoline),
                          (gpointer)CFBridgingRetain([block copy]), MsgBlockFreeHelper, 0);
}

void *ob_script_new(void *session, NSString *source, NSString **outErr) {
    GError *e = NULL;
    void *sc = p_script_new_sync(session, source.UTF8String, NULL, NULL, &e);
    ErrOut(e, outErr);
    return sc;
}

void ob_script_on_message(void *script, void (^block)(NSString *, NSData *)) {
    g_signal_connect_data(script, "message", G_CALLBACK(msg_trampoline),
                          (gpointer)CFBridgingRetain([block copy]), MsgBlockFreeHelper, 0);
}

BOOL ob_script_load(void *script, NSString **outErr) {
    GError *e = NULL;
    p_script_load_sync(script, NULL, &e);
    return !ErrOut(e, outErr);
}

BOOL ob_script_unload(void *script, NSString **outErr) {
    GError *e = NULL;
    p_script_unload_sync(script, NULL, &e);
    return !ErrOut(e, outErr);
}

void ob_script_post(void *script, NSString *json, NSData *data) {
    GBytes *gb = NULL;
    if (data.length) gb = g_bytes_new(data.bytes, data.length);
    p_script_post(script, json.UTF8String, gb);
    if (gb) g_bytes_unref(gb);
}

BOOL ob_detach(void *session, NSString **outErr) {
    GError *e = NULL;
    p_detach_sync(session, NULL, &e);
    return !ErrOut(e, outErr);
}

void ob_close_manager(void) {
    GError *e = NULL;
    p_mgr_close_sync(mgrOnce(), NULL, &e);
    ErrOut(e, NULL);
}

void ob_release(void *gobject) {
    if (gobject) g_object_unref(gobject);
}
