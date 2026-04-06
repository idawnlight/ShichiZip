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
    __block NSString *result = nil;

    void (^showDialog)(void) = ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Password Required";
        alert.informativeText = context
            ? [NSString stringWithFormat:@"Enter password for \"%@\":", context]
            : @"This archive is encrypted. Enter password:";
        alert.alertStyle = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
        input.placeholderString = @"Password";
        alert.accessoryView = input;
        [alert.window setInitialFirstResponder:input];

        NSModalResponse resp = [alert runModal];
        if (resp == NSAlertFirstButtonReturn) {
            result = input.stringValue;
        }
    };

    if ([NSThread isMainThread]) {
        showDialog();
    } else {
        dispatch_sync(dispatch_get_main_queue(), showDialog);
    }

    if (result && result.length > 0) {
        outPassword = ToU(result);
        wasDefined = true;
        return S_OK;
    }
    return E_ABORT;
}
