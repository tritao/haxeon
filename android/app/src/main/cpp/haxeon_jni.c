#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>

#include <pthread.h>
#include <string.h>
#include <limits.h>
#include <stdbool.h>
#include <stdlib.h>

#include <hl.h>
#include <hlmodule.h>

#define HAXEON_LOG_TAG "Haxeon"

static pthread_mutex_t runtime_mutex = PTHREAD_MUTEX_INITIALIZER;
static hl_runtime_module *runtime_module = NULL;
static int runtime_entry_id = -1;
static bool runtime_initialized = false;

static int read_asset(AAssetManager *assets, const char *name, unsigned char **bytes, int *size) {
    AAsset *asset = AAssetManager_open(assets, name, AASSET_MODE_BUFFER);
    if (asset == NULL)
        return 0;

    off_t length = AAsset_getLength(asset);
    if (length <= 0 || length > INT_MAX) {
        AAsset_close(asset);
        return 0;
    }

    unsigned char *data = (unsigned char*)malloc((size_t)length);
    if (data == NULL) {
        AAsset_close(asset);
        return 0;
    }

    int read = AAsset_read(asset, data, (size_t)length);
    AAsset_close(asset);
    if (read != length) {
        free(data);
        return 0;
    }

    *bytes = data;
    *size = read;
    return 1;
}

static int read_entry_id(AAssetManager *assets, int *entry_id) {
    unsigned char *bytes = NULL;
    int size = 0;
    if (!read_asset(assets, "app.entry", &bytes, &size) || size == 0) {
        free(bytes);
        return 0;
    }

    long value = 0;
    for (int i = 0; i < size; ++i) {
        if (bytes[i] < '0' || bytes[i] > '9' || value > (INT_MAX - (bytes[i] - '0')) / 10) {
            free(bytes);
            return 0;
        }
        value = value * 10 + (bytes[i] - '0');
    }
    free(bytes);
    *entry_id = (int)value;
    return 1;
}

static void begin_runtime(void) {
    if (runtime_initialized)
        return;

    hl_global_init();
    hl_setup.file_path = (pchar*)"app.hl";
    hl_setup.sys_args = NULL;
    hl_setup.sys_nargs = 0;
    hl_sys_init();
    runtime_initialized = true;
}

static bool register_current_thread(int *stack_marker) {
    if (hl_get_thread() != NULL)
        return false;
    hl_register_thread(stack_marker);
    return true;
}

static void report_exception(vdynamic *exception, const char *operation) {
    if (exception != NULL) {
        __android_log_print(ANDROID_LOG_ERROR, HAXEON_LOG_TAG, "%s raised a HashLink exception", operation);
        hl_print_uncaught_exception(exception);
    }
}

JNIEXPORT jint JNICALL
Java_org_haxeon_android_MainActivity_nativeLoad(JNIEnv *env, jclass clazz, jobject asset_manager) {
    (void)clazz;

    AAssetManager *assets = AAssetManager_fromJava(env, asset_manager);
    unsigned char *bytes = NULL, *identity = NULL;
    int size = 0, identity_size = 0, entry_id = -1;
    int stack_marker = 0;
    bool registered = false;

    if (assets == NULL || !read_asset(assets, "app.hl", &bytes, &size)
        || !read_asset(assets, "app.hli", &identity, &identity_size)
        || !read_entry_id(assets, &entry_id)) {
        free(bytes);
        free(identity);
        __android_log_print(ANDROID_LOG_ERROR, HAXEON_LOG_TAG,
            "missing app.hl, app.hli, or app.entry asset");
        return 2;
    }

    pthread_mutex_lock(&runtime_mutex);
    if (runtime_module != NULL) {
        pthread_mutex_unlock(&runtime_mutex);
        free(bytes);
        free(identity);
        return HL_RUNTIME_BAD_ARGUMENT;
    }

    begin_runtime();
    registered = register_current_thread(&stack_marker);
    hl_runtime_module *loaded = NULL;
    hl_runtime_status status = hl_runtime_module_load(bytes, size, identity, identity_size, &loaded);
    free(bytes);
    free(identity);
    if (status != HL_RUNTIME_OK || loaded == NULL) {
        __android_log_print(ANDROID_LOG_ERROR, HAXEON_LOG_TAG,
            "could not load app.hl/app.hli (status %d)", status);
        if (registered)
            hl_unregister_thread();
        hl_global_free();
        runtime_initialized = false;
        pthread_mutex_unlock(&runtime_mutex);
        return status;
    }

    runtime_module = loaded;
    runtime_entry_id = entry_id;
    __android_log_print(ANDROID_LOG_INFO, HAXEON_LOG_TAG,
        "loaded app.hl (%d bytes), entry stable ID %d", size, runtime_entry_id);
    vdynamic *exception = NULL;
    status = hl_runtime_module_call_void(runtime_module, runtime_entry_id, &exception);
    if (status != HL_RUNTIME_OK)
        report_exception(exception, "initial app.main");
    else
        __android_log_print(ANDROID_LOG_INFO, HAXEON_LOG_TAG, "initial app.main completed");
    if (registered)
        hl_unregister_thread();
    pthread_mutex_unlock(&runtime_mutex);
    return HL_RUNTIME_OK;
}

JNIEXPORT jint JNICALL
Java_org_haxeon_android_MainActivity_nativeApplyPatch(JNIEnv *env, jclass clazz, jbyteArray patch_array) {
    (void)clazz;
    if (patch_array == NULL)
        return HL_RUNTIME_BAD_ARGUMENT;

    jsize length = (*env)->GetArrayLength(env, patch_array);
    if (length <= 0 || length > 32 * 1024 * 1024)
        return HL_RUNTIME_BAD_ARGUMENT;

    unsigned char *bytes = (unsigned char*)malloc((size_t)length);
    if (bytes == NULL)
        return HL_RUNTIME_JIT_FAILED;
    (*env)->GetByteArrayRegion(env, patch_array, 0, length, (jbyte*)bytes);

    int stack_marker = 0;
    pthread_mutex_lock(&runtime_mutex);
    if (runtime_module == NULL) {
        pthread_mutex_unlock(&runtime_mutex);
        free(bytes);
        return HL_RUNTIME_BAD_ARGUMENT;
    }
    bool registered = register_current_thread(&stack_marker);
    hl_runtime_status status = hl_runtime_module_apply_hlp(runtime_module, bytes, length);
    free(bytes);
    if (status == HL_RUNTIME_OK) {
        vdynamic *exception = NULL;
        hl_runtime_status call_status = hl_runtime_module_call_void(runtime_module, runtime_entry_id, &exception);
        if (call_status != HL_RUNTIME_OK)
            report_exception(exception, "patched app.main");
        __android_log_print(ANDROID_LOG_INFO, HAXEON_LOG_TAG,
            "applied HLP; runtime revision is now %d", hl_runtime_module_revision(runtime_module));
    } else {
        __android_log_print(ANDROID_LOG_ERROR, HAXEON_LOG_TAG,
            "rejected HLP (status %d, runtime revision %d)", status, hl_runtime_module_revision(runtime_module));
    }
    if (registered)
        hl_unregister_thread();
    pthread_mutex_unlock(&runtime_mutex);
    return status;
}

JNIEXPORT jint JNICALL
Java_org_haxeon_android_MainActivity_nativeRevision(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    pthread_mutex_lock(&runtime_mutex);
    int revision = runtime_module == NULL ? 0 : hl_runtime_module_revision(runtime_module);
    pthread_mutex_unlock(&runtime_mutex);
    return revision;
}

JNIEXPORT jint JNICALL
Java_org_haxeon_android_MainActivity_nativeDispose(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    int stack_marker = 0;
    pthread_mutex_lock(&runtime_mutex);
    if (runtime_module == NULL) {
        pthread_mutex_unlock(&runtime_mutex);
        return 0;
    }
    bool registered = register_current_thread(&stack_marker);
    hl_runtime_status status = hl_runtime_module_release(runtime_module);
    if (status == HL_RUNTIME_OK) {
        runtime_module = NULL;
        runtime_entry_id = -1;
        hl_runtime_failed_retirements_retry();
        hl_global_free();
        runtime_initialized = false;
        __android_log_print(ANDROID_LOG_INFO, HAXEON_LOG_TAG, "released HashLink runtime");
    } else {
        __android_log_print(ANDROID_LOG_ERROR, HAXEON_LOG_TAG,
            "could not release HashLink runtime (status %d)", status);
    }
    if (registered)
        hl_unregister_thread();
    pthread_mutex_unlock(&runtime_mutex);
    return status;
}
