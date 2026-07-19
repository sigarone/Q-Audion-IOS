#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try/@catch`. Swift's `do/catch` and
/// `try` can only intercept Swift `Error`s — they CANNOT catch an ObjC
/// `NSException`, which instead unwinds straight past Swift frames and aborts
/// the process (SIGABRT). Some AVFAudio calls (notably
/// `-[AVAudioIONode setVoiceProcessingEnabled:error:]`, which internally
/// reconnects the engine graph) raise an `NSException` rather than returning a
/// Swift error when the hardware VoiceProcessingIO unit is already claimed by
/// another engine (e.g. a concurrent LiveKit group call). This shim lets Swift
/// degrade gracefully instead of crashing.
///
/// Returns `YES` if `block` ran without raising. On an `NSException` it returns
/// `NO` and, when `outError` is non-NULL, sets it to an `NSError` carrying the
/// exception name + reason.
BOOL QAudionRunCatchingNSException(void (NS_NOESCAPE ^block)(void),
                                   NSError * _Nullable * _Nullable outError);

NS_ASSUME_NONNULL_END
