//
//  Hooking.c
//  WindowServerFramework
//
//  Created by bedtime on 10/26/26.
//

#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld.h>
#include <ptrauth.h>
#include "WXFHooks-Private.h"
#include <WindowServerFramework/WXFHost.h>

typedef bool (*GumInterceptorReplaceIMP)(void *, void *, void *, void *, void **);
typedef void (*GumInterceptorTransactionIMP)(void *);

static void *FindServerSymbol(const char *wanted) {
    static const struct nlist_64 *syms;
    static const char *strs;
    static uint32_t nsyms, strsize;
    static uintptr_t slide;

    if (!syms) {
        void *anchor = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        Dl_info di;
        if (!anchor || !dladdr(anchor, &di)) return NULL;
        const struct mach_header_64 *mh = (const struct mach_header_64 *)di.dli_fbase;
        if (!mh || mh->magic != MH_MAGIC_64) return NULL;

        const struct load_command *lc = (const void *)(mh + 1);
        const struct symtab_command *st = NULL;
        const struct segment_command_64 *le = NULL, *tx = NULL;
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            if (lc->cmd == LC_SYMTAB) {
                st = (const void *)lc;
            } else if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const void *)lc;
                if (strcmp(sg->segname, "__LINKEDIT") == 0) le = sg;
                else if (strcmp(sg->segname, "__TEXT") == 0) tx = sg;
            }
            lc = (const void *)((const char *)lc + lc->cmdsize);
        }
        if (!st || !le || !tx) return NULL;

        slide   = (uintptr_t)mh - (uintptr_t)tx->vmaddr;
        uintptr_t linkedit = (uintptr_t)le->vmaddr + slide - (uintptr_t)le->fileoff;
        syms    = (const void *)(linkedit + st->symoff);
        strs    = (const char *)(linkedit + st->stroff);
        nsyms   = st->nsyms;
        strsize = st->strsize;
    }

    for (uint32_t i = 0; i < nsyms; i++) {
        uint32_t off = syms[i].n_un.n_strx;
        if (off >= strsize) continue;
        if (strcmp(strs + off, wanted) != 0) continue;
        if (syms[i].n_value == 0) continue;
        void *raw = (void *)((uintptr_t)syms[i].n_value + slide);
        return ptrauth_sign_unauthenticated(raw, ptrauth_key_function_pointer, 0);
    }
    return NULL;
}

void *gInterceptor = NULL;

// Looks up a WindowServer (SkyLight) symbol by its raw Mach-O name, e.g. "_CGXGetCurrentCursorLocation".
// Returns a callable function pointer, or NULL if it isn't present on this OS build.
bool WXFIsFrameworkSetUp(void) {
    return gInterceptor != NULL;
}

void *WXFResolveServerSymbol(const char *Wanted) {
    return FindServerSymbol(Wanted);
}

// FindServerSymbol signs what it finds like a function pointer; for data that has to come off again.
void *WXFResolveServerData(const char *Wanted) {
    void *symbol = FindServerSymbol(Wanted);
    return symbol ? ptrauth_strip(symbol, ptrauth_key_function_pointer) : NULL;
}


extern int sandbox_init_with_parameters(const char *profile, uint64_t flags, const char **params, char **errorbuf);
int sandbox_init_with_parameters_new(const char *profile, uint64_t flags, const char **params, char **errorbuf) {
            return 0;
}


__attribute__((visibility("default")))
void SetupFramework(void * ammonia_gum_interceptor) {
    // Every tweak calls this with Ammonia's interceptor; the framework is one shared dylib, so the
    // first call wins and later calls just make sure the startup hooks are in.
    if (gInterceptor == NULL)
        gInterceptor = ammonia_gum_interceptor;
    // The startup hooks are WindowServer's; the same SkyLight image is mapped into every process,
    // but hooking its server-only functions anywhere else would do nothing but cost.
    if (WXFGetHost() == WXFHostWindowServer)
        WXFHooksInstallAll();
}

// resolver compares raw Mach-O names, so make sure Wanted uses the exact spelling stored in the table.
void HookServer(const char *Wanted, void * ReplacementFunc, void **OriginalPtr) {
    if (gInterceptor == NULL) {
        return;
    }
    void * targ = FindServerSymbol(Wanted);
    if (targ == NULL) {
        return;
    }

    GumInterceptorReplaceIMP replace = (GumInterceptorReplaceIMP)dlsym(RTLD_DEFAULT,
                                                                       "gum_interceptor_replace");
    GumInterceptorTransactionIMP begin = (GumInterceptorTransactionIMP)dlsym(
        RTLD_DEFAULT, "gum_interceptor_begin_transaction");
    GumInterceptorTransactionIMP end = (GumInterceptorTransactionIMP)dlsym(
        RTLD_DEFAULT, "gum_interceptor_end_transaction");
    if (replace == NULL || begin == NULL || end == NULL) {
        return;
    }

    begin(gInterceptor);
    replace(gInterceptor,
            targ,
            ReplacementFunc,
            NULL,
            OriginalPtr);
    
    end(gInterceptor);
}
