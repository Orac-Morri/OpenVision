//
//  OVExceptionCatcher.m
//  OpenVision
//

#import "OVExceptionCatcher.h"

NSString * _Nullable OVCatchException(void (^block)(void)) {
    @try {
        block();
        return nil;
    }
    @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}
