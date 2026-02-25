#import "ObjCExceptionCatcher.h"

NSException * _Nullable ObjCTryCatch(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
