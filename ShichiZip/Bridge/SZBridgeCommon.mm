// SZBridgeCommon.mm — Shared bridge infrastructure (codecs, password, GUIDs)

// This TU defines INITGUID so all IID constants are instantiated here
#define INITGUID

#include "SZBridgeCommon.h"

NSString * const SZArchiveErrorDomain = @"SZArchiveErrorDomain";

// ============================================================
// Codec manager singleton
// ============================================================

static CCodecs *g_Codecs = nullptr;
static bool g_CodecsInitialized = false;

CCodecs *SZGetCodecs() {
    if (!g_CodecsInitialized) {
        CrcGenerateTable();
        g_Codecs = new CCodecs;
        if (g_Codecs->Load() != S_OK) { delete g_Codecs; g_Codecs = nullptr; }
        g_CodecsInitialized = true;
    }
    return g_Codecs;
}

// ============================================================
// Password prompt
// ============================================================

HRESULT SZPromptForPassword(UString &outPassword, bool &wasDefined, NSString *context) {
    __block NSString *result = @"";
    __block BOOL confirmed = NO;

    void (^showDialog)(void) = ^{
        NSString *message = context.length > 0
            ? [NSString stringWithFormat:@"Enter password for \"%@\".", context]
            : @"This archive is encrypted. Enter password.";
        confirmed = [SZDialogPresenter promptForPasswordWithTitle:@"Password Required"
                                                          message:message
                                                     initialValue:wasDefined ? ToNS(outPassword) : nil
                                                          password:&result];
    };

    if ([NSThread isMainThread]) {
        showDialog();
    } else {
        dispatch_sync(dispatch_get_main_queue(), showDialog);
    }

    if (confirmed) {
        outPassword = ToU(result);
        wasDefined = true;
        return S_OK;
    }
    return E_ABORT;
}
