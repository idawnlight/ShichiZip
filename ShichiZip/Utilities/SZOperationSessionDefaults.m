#import "SZOperationSessionDefaults.h"

#import "../Dialogs/SZDialogPresenter.h"

SZOperationSession* SZMakeDefaultOperationSession(id<SZProgressDelegate> progressDelegate) {
    SZOperationSession* session = [SZOperationSession new];
    session.progressDelegate = progressDelegate;
    session.passwordRequestHandler = ^BOOL(NSString* title,
        NSString* message,
        NSString* initialValue,
        NSString* _Nullable* _Nullable password) {
        return [SZDialogPresenter promptForPasswordWithTitle:title
                                                     message:message
                                                initialValue:initialValue
                                                    password:password];
    };
    session.choiceRequestHandler = ^NSInteger(SZOperationChoiceRequest* request) {
        return [SZDialogPresenter runChoiceRequest:request];
    };
    return session;
}
