#import "QAudionVPIOSafe.h"

BOOL QAudionRunCatchingNSException(void (NS_NOESCAPE ^block)(void),
                                   NSError * _Nullable * _Nullable outError) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outError != NULL) {
            NSString *reason = exception.reason ?: @"";
            NSString *name = exception.name ?: @"NSException";
            *outError = [NSError errorWithDomain:@"QAudionVPIOSafe"
                                            code:1
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", name, reason]
            }];
        }
        return NO;
    }
}
