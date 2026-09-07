// obsmoke.c — 注入引擎 C 套件冒烟(Phase 0):
//   1) dlsym + base64 符号名:源码零明文 API 名,链接用 -force_load + -export_dynamic 保符号可见
//   2) 线程模型:专用 loop 线程(套件 init + 默认 GMainLoop),worker 线程发 _sync 调用
//   3) RPC 往返:post(JSON) → 脚本 recv → send 回包 → message 信号收
//   4) 设备 Java 桥 sanity
//
// 编译(通用二进制):
//   clang -arch arm64 -arch x86_64 tools/obsmoke.c -o /tmp/obsmoke \
//     -I "$HOME/.obkit/16.7.19" \
//     -Wl,-force_load,"$HOME/.obkit/16.7.19/libobcore.a" -Wl,-export_dynamic \
//     -lbsm -ldl -lm -lresolv -Wl,-framework,Foundation,-framework,AppKit
//
// 运行前置: 手机端引擎服务在跑(UURemote 已映射 27042),或 USB 直插。
#include "obcore.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ---- 函数指针(中性名) ----
static void               (*p_init)(void);
static void              *(*p_mgr_new)(void);
static void              *(*p_mgr_by_type_sync)(void *, int, int, void *, void **);
static void              *(*p_mgr_remote_sync)(void *, const char *, void *, void *, void **);
static void              *(*p_proc_by_name_sync)(void *, const char *, void *, void *, void **);
static unsigned           (*p_proc_pid)(void *);
static const char        *(*p_dev_name)(void *);
static void              *(*p_attach_sync)(void *, unsigned, void *, void *, void **);
static void              *(*p_script_new_sync)(void *, const char *, void *, void *, void **);
static void               (*p_script_load_sync)(void *, void *, void **);
static void               (*p_script_unload_sync)(void *, void *, void **);
static void               (*p_script_post)(void *, const char *, void *);
static void               (*p_detach_sync)(void *, void *, void **);
static void               (*p_mgr_close_sync)(void *, void *, void **);

// ---- 符号表(base64) ----
static const char *kSyms[] = {
    "ZnJpZGFfaW5pdA==",                                             // [0]
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfbmV3",
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfZ2V0X2RldmljZV9ieV90eXBlX3N5bmM=",
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfYWRkX3JlbW90ZV9kZXZpY2Vfc3luYw==",
    "ZnJpZGFfZGV2aWNlX2dldF9wcm9jZXNzX2J5X25hbWVfc3luYw==",
    "ZnJpZGFfcHJvY2Vzc19nZXRfcGlk",
    "ZnJpZGFfZGV2aWNlX2F0dGFjaF9zeW5j",
    "ZnJpZGFfc2Vzc2lvbl9jcmVhdGVfc2NyaXB0X3N5bmM=",
    "ZnJpZGFfc2NyaXB0X2xvYWRfc3luYw==",
    "ZnJpZGFfc2NyaXB0X3VubG9hZF9zeW5j",
    "ZnJpZGFfc2NyaXB0X3Bvc3Q=",
    "ZnJpZGFfc2Vzc2lvbl9kZXRhY2hfc3luYw==",
    "ZnJpZGFfZGV2aWNlX21hbmFnZXJfY2xvc2Vfc3luYw==",
    "ZnJpZGFfZGV2aWNlX2dldF9uYW1l",
};

static int b64dec(const char *in, char *out, int cap) {
    static const char *T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int v = 0, bits = 0, n = 0;
    for (; *in && *in != '='; in++) {
        const char *f = strchr(T, *in);
        if (!f) return -1;
        v = (v << 6) | (int)(f - T);
        bits += 6;
        if (bits >= 8) { bits -= 8; out[n++] = (char)((v >> bits) & 0xFF); if (n >= cap) return -1; }
    }
    out[n] = 0;
    return n;
}

static void *syms[sizeof(kSyms) / sizeof(kSyms[0])];

static void load_syms(void) {
    char name[128];
    for (unsigned i = 0; i < sizeof(kSyms) / sizeof(kSyms[0]); i++) {
        if (b64dec(kSyms[i], name, sizeof(name)) < 0) { fprintf(stderr, "[x] b64 %u\n", i); exit(1); }
        syms[i] = dlsym(RTLD_DEFAULT, name);
        if (!syms[i]) { fprintf(stderr, "[x] dlsym 未找到: %s(-force_load/-export_dynamic 检查)\n", name); exit(1); }
    }
    p_init                = syms[0];
    p_mgr_new             = syms[1];
    p_mgr_by_type_sync    = syms[2];
    p_mgr_remote_sync     = syms[3];
    p_proc_by_name_sync   = syms[4];
    p_proc_pid            = syms[5];
    p_attach_sync         = syms[6];
    p_script_new_sync     = syms[7];
    p_script_load_sync    = syms[8];
    p_script_unload_sync  = syms[9];
    p_script_post         = syms[10];
    p_detach_sync         = syms[11];
    p_mgr_close_sync      = syms[12];
    p_dev_name            = syms[13];
}

// ---- 脚本源(无敏感词;收请求回 echo,报自身 pid/架构,探 Java 桥) ----
static const char *JS =
    "'use strict';\n"
    "function onReq(m) {\n"
    "  if (m.op === 'echo') send({ id: m.id, ok: true, echo: m.payload });\n"
    "  else send({ id: m.id, ok: false, err: 'unknown op' });\n"
    "  recv(onReq);\n"
    "}\n"
    "recv(onReq);\n"
    "send({ ev: 'ready', pid: Process.id, arch: Process.arch });\n"
    "Java.perform(function () { send({ ev: 'java', ok: true }); });\n";

// ---- 应答同步(历史环形缓冲:ready/java 在 load 期间就到,入口清标志会丢消息) ----
static pthread_mutex_t g_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static char g_hist[32][4096];
static int g_hist_n = 0;

static void on_message(void *script, const char *message, GBytes *data, gpointer ud) {
    (void)script; (void)data; (void)ud;
    pthread_mutex_lock(&g_mx);
    if (g_hist_n < 32)
        snprintf(g_hist[g_hist_n++], sizeof(g_hist[0]), "%s", message ? message : "(null)");
    pthread_cond_signal(&g_cv);
    pthread_mutex_unlock(&g_mx);
}

static void on_detached(void *session, int reason, void *crash, gpointer ud) {
    (void)session; (void)crash; (void)ud;
    fprintf(stderr, "[!] 会话被分离 reason=%d\n", reason);
}

static void *loop_thread(void *arg) {
    (void)arg;
    p_init();                                    // 必须先于一切套件 API
    GMainLoop *loop = g_main_loop_new(NULL, TRUE);
    g_main_loop_run(loop);                       // 承载 message/detached 信号
    return NULL;
}

// 在历史里找含 want 子串的消息;没有则等新消息,直到超时。命中返回该条(静态存储,勿释放)
static const char *wait_msg(const char *want, int secs) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += secs;
    pthread_mutex_lock(&g_mx);
    for (;;) {
        for (int i = 0; i < g_hist_n; i++)
            if (!want || strstr(g_hist[i], want)) { pthread_mutex_unlock(&g_mx); return g_hist[i]; }
        if (pthread_cond_timedwait(&g_cv, &g_mx, &ts) != 0) break;
    }
    pthread_mutex_unlock(&g_mx);
    return NULL;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    load_syms();
    printf("[1] 符号表 %zu 个全部就位(dlsym)\n", sizeof(syms) / sizeof(syms[0]));

    pthread_t t;
    pthread_create(&t, NULL, loop_thread, NULL);
    sleep(1);                                    // 等 loop 线程完成 init
    printf("[2] loop 线程就绪(init + 主上下文)\n");

    GError *err = NULL;
    void *mgr = p_mgr_new();

    // USB 优先,失败退远程 127.0.0.1:27042(与参考脚本 auto 语义一致)
    void *dev = p_mgr_by_type_sync(mgr, 2 /*设备类型:USB*/, 3, NULL, &err);
    if (err) {
        fprintf(stderr, "[i] USB 设备不可用(%s),退远程…\n", err->message);
        g_error_free(err); err = NULL;
        dev = p_mgr_remote_sync(mgr, "127.0.0.1:27042", NULL, NULL, &err);
    }
    if (err || !dev) { fprintf(stderr, "[x] 无设备: %s\n", err ? err->message : "null"); return 1; }
    printf("[3] 设备: %s\n", p_dev_name ? p_dev_name(dev) : "(?)");

    char name[64];
    b64dec("QXBwbGUgTXVzaWM=", name, sizeof(name));   // 目标播放器进程名(敏感,base64)
    void *proc = p_proc_by_name_sync(dev, name, NULL, NULL, &err);
    if (err) { fprintf(stderr, "[x] 找进程: %s(手机上播放器在跑?)\n", err->message); return 1; }
    unsigned pid = p_proc_pid(proc);
    printf("[4] 目标进程 pid=%u\n", pid);

    void *session = p_attach_sync(dev, pid, NULL, NULL, &err);
    if (err) { fprintf(stderr, "[x] attach: %s\n", err->message); return 1; }
    g_signal_connect_data(session, "detached", G_CALLBACK(on_detached), NULL, NULL, 0);
    printf("[5] 已 attach\n");

    void *script = p_script_new_sync(session, JS, NULL, NULL, &err);
    if (err) { fprintf(stderr, "[x] 建脚本: %s\n", err->message); return 1; }
    g_signal_connect_data(script, "message", G_CALLBACK(on_message), NULL, NULL, 0);
    p_script_load_sync(script, NULL, &err);
    if (err) { fprintf(stderr, "[x] 加载: %s\n", err->message); return 1; }
    printf("[6] 脚本已加载(worker 线程发的 _sync,未锁死)\n");

    const char *m;
    if (!(m = wait_msg("\"ev\":\"ready\"", 15))) { fprintf(stderr, "[x] 未收到 ready\n"); return 1; }
    printf("[7] 脚本 ready: %s\n", m);
    if ((m = wait_msg("\"ev\":\"java\"", 10)) && strstr(m, "\"ok\":true"))
        printf("[8] 设备 Java 桥通: %s\n", m);
    else
        fprintf(stderr, "[i] Java 桥未确认(不阻塞)\n");

    p_script_post(script, "{\"id\":1,\"op\":\"echo\",\"payload\":\"hello-from-ob\"}", NULL);
    if (!(m = wait_msg("\"id\":1", 15))) { fprintf(stderr, "[x] echo 无回包\n"); return 1; }
    int echo_ok = strstr(m, "\"ok\":true") && strstr(m, "hello-from-ob");
    printf("[9] RPC echo %s: %s\n", echo_ok ? "✅" : "❌", m);

    // 清场:卸脚本 → 分离 → 关管理器 → 退 loop
    p_script_unload_sync(script, NULL, &err);
    if (err) { fprintf(stderr, "[i] unload: %s\n", err->message); err = NULL; }
    p_detach_sync(session, NULL, &err);
    if (err) { fprintf(stderr, "[i] detach: %s\n", err->message); err = NULL; }
    p_mgr_close_sync(mgr, NULL, &err);
    if (err) { fprintf(stderr, "[i] close: %s\n", err->message); err = NULL; }
    g_object_unref(script); g_object_unref(session); g_object_unref(proc);
    g_object_unref(dev); g_object_unref(mgr);

    if (!echo_ok) return 1;
    printf("\n== 冒烟通过:线程模型 + dlsym 符号 + RPC 往返 + Java 桥 全绿 ==\n");
    return 0;
}
