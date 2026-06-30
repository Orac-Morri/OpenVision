//
//  OVExceptionCatcher.h
//  OpenVision
//
//  Bridges Objective-C @try/@catch to Swift. Some Apple APIs (notably
//  AVAudioNode.installTapOnBus) raise NSExceptions that Swift's `try`/`do-catch`
//  cannot catch — an uncaught one aborts the process (SIGABRT). Wrap such calls in
//  OVCatchException to fail gracefully instead of crashing.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, catching any Objective-C exception it raises.
/// Returns the exception's reason (or name) on failure, or nil on success.
NSString * _Nullable OVCatchException(void (^block)(void));

NS_ASSUME_NONNULL_END
