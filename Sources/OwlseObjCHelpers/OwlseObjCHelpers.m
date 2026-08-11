// The MIT License (MIT)
//
// Copyright (c) 2020-2026 Alexander Grebenyuk (github.com/kean).

#import "OwlseObjCHelpers.h"

@implementation OwlseObjCExceptionCatcher

+ (BOOL)performAndReturnError:(NSError **)error block:(void (NS_NOESCAPE ^)(void))block {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.github.kean.owlse"
                                         code:-1
                                     userInfo:@{
                NSLocalizedDescriptionKey: exception.reason ?: @"Unknown Objective-C exception"
            }];
        }
        return NO;
    }
}

@end
