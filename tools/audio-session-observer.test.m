// Runs the production native delegate against controlled WebRTC and Apple activation states.
#import "LKRNAudioDeviceModuleObserver.h"
#import <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "%s:%d: %s\n", __func__, __LINE__, #condition); exit(EXIT_FAILURE); \
} } while (0)

@interface TestAppleSession : NSObject
@property NSUInteger calls;
@property BOOL failNext;
@property BOOL omitError;
@end

@implementation TestAppleSession
- (BOOL)setActive:(BOOL)active error:(NSError **)error {
    CHECK(active);
    self.calls++;
    if (!self.failNext) return YES;
    self.failNext = NO;
    if (!self.omitError) *error = [NSError errorWithDomain:@"AudioSessionTest" code:1 userInfo:nil];
    return NO;
}
@end

@interface TestRTCSession : NSObject
@property(strong) TestAppleSession *session;
@property(copy) NSString *category;
@property BOOL isActive;
@property BOOL useManualAudio;
@property int activationCount;
@property BOOL locked;
@property BOOL externalHoldOnNextConfiguration;
@property BOOL failNextConfiguration;
@property NSUInteger acquisitions;
@property NSUInteger releases;
@end

@implementation TestRTCSession
- (void)lockForConfiguration { CHECK(!self.locked); self.locked = YES; }
- (void)unlockForConfiguration { CHECK(self.locked); self.locked = NO; }
- (BOOL)setConfiguration:(LKRTCAudioSessionConfiguration *)config error:(NSError **)error {
    CHECK(self.locked);
    if (self.failNextConfiguration) {
        self.failNextConfiguration = NO;
        *error = [NSError errorWithDomain:@"AudioSessionTest" code:2 userInfo:nil];
        return NO;
    }
    self.category = config.category;
    if (self.externalHoldOnNextConfiguration) {
        self.externalHoldOnNextConfiguration = NO;
        self.activationCount++;
    }
    return YES;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)error {
    CHECK(self.locked);
    if (active) {
        self.acquisitions++;
        self.activationCount++;
    } else {
        CHECK(self.activationCount > 0);
        self.releases++;
        self.activationCount--;
    }
    self.isActive = self.activationCount > 0;
    return YES;
}
@end

static TestRTCSession *rtc;
static LKRNAudioDeviceModuleObserver *observer;

static id sharedTestSession(id classObject, SEL selector) { return rtc; }

static void reset(BOOL deactivateOnStop) {
    rtc = [TestRTCSession new];
    rtc.session = [TestAppleSession new];
    // Native policy mode never forwards to JavaScript. No React bridge or audio hardware is started.
    LKRNWebRTCModule *unusedModule = nil;
    observer = [[LKRNAudioDeviceModuleObserver alloc] initWithWebRTCModule:unusedModule];
    observer.isWillEnableEngineActive = NO;
    observer.isDidDisableEngineActive = NO;
    observer.automaticAudioSessionConfig = @{
        @"playout": @{@"audioCategory": @"playback"},
        @"recording": @{@"audioCategory": @"playAndRecord"},
        @"deactivateOnStop": @(deactivateOnStop)
    };
}

static NSInteger enable(BOOL recording) {
    id unused = nil;
    NSInteger result = [observer audioDeviceModule:unused willEnableEngine:unused isPlayoutEnabled:YES
                                isRecordingEnabled:recording isVoiceProcessingEnabled:NO];
    CHECK(!rtc.locked);
    return result;
}

static NSInteger stop(void) {
    id unused = nil;
    NSInteger result = [observer audioDeviceModule:unused didDisableEngine:unused isPlayoutEnabled:NO
                                isRecordingEnabled:NO];
    CHECK(!rtc.locked);
    return result;
}

static void ownedTransitions(void) {
    reset(YES);
    CHECK(enable(NO) == 0 && rtc.acquisitions == 1 && rtc.session.calls == 0);
    CHECK(enable(YES) == 0 && rtc.session.calls == 1 && rtc.activationCount == 1);
    CHECK(enable(YES) == 0 && rtc.session.calls == 1);
    CHECK(enable(NO) == 0 && rtc.session.calls == 1);
    CHECK(enable(YES) == 0 && rtc.session.calls == 2);
    CHECK(stop() == 0 && rtc.acquisitions == 1 && rtc.releases == 1 && rtc.activationCount == 0);
    reset(YES);
    CHECK(enable(YES) == 0 && rtc.acquisitions == 1 && rtc.session.calls == 0);
    CHECK(stop() == 0 && rtc.activationCount == 0);
}

static void externalOwnership(void) {
    reset(YES);
    rtc.isActive = YES;
    rtc.activationCount = 1;
    CHECK(enable(NO) == 0 && enable(YES) == 0 && stop() == 0);
    CHECK(rtc.session.calls == 0 && rtc.acquisitions == 0 && rtc.releases == 0 && rtc.activationCount == 1);

    reset(YES);
    CHECK(enable(NO) == 0);
    rtc.useManualAudio = YES;
    CHECK(enable(YES) == 0 && rtc.session.calls == 0);
    CHECK(stop() == 0 && rtc.activationCount == 0);

    reset(YES);
    CHECK(enable(NO) == 0);
    rtc.activationCount++; // A second consumer acquired a WebRTC hold before the category switch.
    CHECK(enable(YES) == 0 && rtc.session.calls == 0);
    CHECK(stop() == 0 && rtc.activationCount == 1);

    reset(YES);
    CHECK(enable(NO) == 0);
    rtc.externalHoldOnNextConfiguration = YES; // Ownership changes inside setConfiguration:error:.
    CHECK(enable(YES) == 0 && rtc.session.calls == 0);
    CHECK(stop() == 0 && rtc.activationCount == 1);
}

static void refreshFailure(BOOL omitError) {
    reset(YES);
    CHECK(enable(NO) == 0);
    rtc.session.failNext = YES;
    rtc.session.omitError = omitError;
    CHECK(enable(YES) == -4100 && rtc.session.calls == 1 && rtc.activationCount == 1);
    CHECK([rtc.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]);
    CHECK(enable(YES) == 0 && rtc.session.calls == 2 && rtc.activationCount == 1);
    CHECK(enable(YES) == 0 && rtc.session.calls == 2);
    CHECK(stop() == 0 && rtc.acquisitions == 1 && rtc.releases == 1);
}

static void failedConfigurationAndAbandonedRetry(void) {
    reset(YES);
    CHECK(enable(NO) == 0);
    rtc.failNextConfiguration = YES;
    CHECK(enable(YES) == -4100 && rtc.session.calls == 0);
    CHECK(enable(YES) == 0 && rtc.session.calls == 1);
    CHECK(stop() == 0 && rtc.activationCount == 0);

    reset(NO);
    CHECK(enable(NO) == 0);
    rtc.session.failNext = YES;
    CHECK(enable(YES) == -4100 && rtc.session.calls == 1);
    CHECK(stop() == 0 && rtc.activationCount == 1);
    CHECK(enable(YES) == 0 && rtc.session.calls == 1); // The stop canceled the pending retry.
    observer.automaticAudioSessionConfig = nil;
    CHECK(stop() == 0 && rtc.activationCount == 0);
}

int main(void) {
    @autoreleasepool {
        Method shared = class_getClassMethod([LKRTCAudioSession class], @selector(sharedInstance));
        CHECK(shared != NULL);
        IMP original = method_setImplementation(shared, (IMP)sharedTestSession);
        ownedTransitions();
        externalOwnership();
        refreshFailure(NO);
        refreshFailure(YES);
        failedConfigurationAndAbandonedRetry();
        method_setImplementation(shared, original);
        puts("Passed iOS audio-session ownership and retry checks");
    }
    return 0;
}
