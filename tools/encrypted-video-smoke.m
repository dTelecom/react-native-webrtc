// Loopback test against the M150 framework, using synthetic video and no cloud credentials.
// Run once with "match" and once with "mismatch". A passing negative needs a native decrypt error.
#import <Foundation/Foundation.h>
#import <LiveKitWebRTC/LiveKitWebRTC.h>

static void Require(BOOL ok, NSString *description) {
    if (!ok) {
        fprintf(stderr, "FAIL %s\n", description.UTF8String);
        exit(1);
    }
}

static BOOL WaitUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return done();
}

@interface Probe : NSObject <LKRTCPeerConnectionDelegate, LKRTCVideoRenderer, LKRTCFrameCryptorDelegate>
@property(atomic, strong) LKRTCRtpReceiver *receiver;
@property(atomic) NSUInteger decodedPatterns;
@property(atomic) BOOL decryptFailed;
@end

@implementation Probe
- (void)peerConnection:(LKRTCPeerConnection *)pc didAddReceiver:(LKRTCRtpReceiver *)receiver
               streams:(NSArray<LKRTCMediaStream *> *)streams {
    // The native bridge applies this gate before sending the track event to JS.
    receiver.track.isEnabled = NO;
    if ([receiver.track isKindOfClass:LKRTCVideoTrack.class]) self.receiver = receiver;
}
- (void)setSize:(CGSize)size {}
- (void)renderFrame:(LKRTCVideoFrame *)frame {
    if (!frame) return;
    id<LKRTCI420Buffer> pixels = frame.buffer.toI420;
    if (pixels.dataY[(pixels.height / 2) * pixels.strideY + pixels.width / 2] > 100) {
        self.decodedPatterns++;
    }
}
- (void)frameCryptor:(LKRTCFrameCryptor *)cryptor didStateChangeWithParticipantId:(NSString *)participant
           withState:(LKRTCFrameCryptorState)state {
    if (state == LKRTCFrameCryptorStateDecryptionFailed) self.decryptFailed = YES;
}
- (void)peerConnection:(LKRTCPeerConnection *)pc didChangeSignalingState:(LKRTCSignalingState)state {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didChangeIceConnectionState:(LKRTCIceConnectionState)state {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didChangeIceGatheringState:(LKRTCIceGatheringState)state {}
- (void)peerConnectionShouldNegotiate:(LKRTCPeerConnection *)pc {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didAddStream:(LKRTCMediaStream *)stream {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didRemoveStream:(LKRTCMediaStream *)stream {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didGenerateIceCandidate:(LKRTCIceCandidate *)ice {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didRemoveIceCandidates:(NSArray<LKRTCIceCandidate *> *)ice {}
- (void)peerConnection:(LKRTCPeerConnection *)pc didOpenDataChannel:(LKRTCDataChannel *)dc {}
@end

static LKRTCFrameCryptorKeyProvider *Key(NSString *text) {
    LKRTCFrameCryptorKeyProvider *provider = [[LKRTCFrameCryptorKeyProvider alloc]
        initWithRatchetSalt:[@"LKFrameEncryptionKey" dataUsingEncoding:NSUTF8StringEncoding]
        ratchetWindowSize:8 sharedKeyMode:YES uncryptedMagicBytes:nil failureTolerance:0 keyRingSize:16
        discardFrameWhenCryptorNotReady:YES keyDerivationAlgorithm:LKRTCKeyDerivationAlgorithmPBKDF2];
    [provider setSharedKey:[text dataUsingEncoding:NSUTF8StringEncoding] withIndex:0];
    return provider;
}

static void Signal(LKRTCPeerConnection *from, LKRTCPeerConnection *to, LKRTCMediaConstraints *constraints, BOOL offer) {
    __block LKRTCSessionDescription *sdp;
    __block NSError *error;
    void (^created)(LKRTCSessionDescription *, NSError *) = ^(LKRTCSessionDescription *description, NSError *err) {
        sdp = description;
        error = err;
    };
    if (offer) [from offerForConstraints:constraints completionHandler:created];
    else [from answerForConstraints:constraints completionHandler:created];
    Require(WaitUntil(10, ^BOOL { return sdp != nil || error != nil; }) && !error, @"SDP creation");
    __block BOOL applied = NO;
    [from setLocalDescription:sdp completionHandler:^(NSError *err) { error = err; applied = YES; }];
    Require(WaitUntil(10, ^BOOL { return applied; }) && !error, @"local description");
    Require(WaitUntil(15, ^BOOL { return from.iceGatheringState == LKRTCIceGatheringStateComplete; }),
            @"ICE gathering");
    applied = NO;
    [to setRemoteDescription:from.localDescription completionHandler:^(NSError *err) { error = err; applied = YES; }];
    Require(WaitUntil(10, ^BOOL { return applied; }) && !error, @"remote description");
}

static void SendFrames(LKRTCVideoSource *source, LKRTCVideoCapturer *capturer, int count) {
    LKRTCMutableI420Buffer *image = [[LKRTCMutableI420Buffer alloc] initWithWidth:160 height:120];
    memset(image.mutableDataY, 195, image.strideY * image.height);
    memset(image.mutableDataU, 115, image.strideU * image.chromaHeight);
    memset(image.mutableDataV, 140, image.strideV * image.chromaHeight);
    for (int n = 0; n < count; ++n) {
        LKRTCVideoFrame *frame = [[LKRTCVideoFrame alloc] initWithBuffer:image rotation:LKRTCVideoRotation_0
            timeStampNs:(int64_t)(NSProcessInfo.processInfo.systemUptime * 1000000000)];
        [source capturer:capturer didCaptureVideoFrame:frame];
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
}

static NSUInteger SentPackets(LKRTCPeerConnection *pc, LKRTCRtpSender *sender) {
    __block LKRTCStatisticsReport *report;
    [pc statisticsForSender:sender completionHandler:^(LKRTCStatisticsReport *result) { report = result; }];
    Require(WaitUntil(5, ^BOOL { return report != nil; }), @"outbound sender statistics");
    NSUInteger packets = 0;
    for (LKRTCStatistics *row in report.statistics.allValues) {
        if ([row.type isEqualToString:@"outbound-rtp"]) packets += [(NSNumber *)row.values[@"packetsSent"] unsignedIntegerValue];
    }
    return packets;
}

static void StageNewVideoReceiver(LKRTCPeerConnection *subscriber, LKRTCSessionDescription *realOffer,
                                  NSString *mid, LKRTCFrameCryptorKeyProvider *key, Probe *probe, void (^whileHeld)(void),
                                  LKRTCPeerConnectionFactory *factory, LKRTCFrameCryptor **cryptor) {
    NSArray<NSString *> *sections = [realOffer.sdp componentsSeparatedByString:@"\r\nm="];
    NSMutableArray<NSString *> *heldSections = [NSMutableArray new];
    NSString *attribute = [NSString stringWithFormat:@"a=mid:%@", mid];
    NSString *previousReceiverId = probe.receiver.receiverId;
    for (NSString *section in sections) {
        NSMutableArray<NSString *> *lines = [[section componentsSeparatedByString:@"\r\n"] mutableCopy];
        if ([lines containsObject:attribute]) {
            NSUInteger index = [lines indexOfObject:@"a=sendonly"];
            Require(index != NSNotFound, @"expected new sending m-line");
            lines[index] = @"a=inactive";
        }
        [heldSections addObject:[lines componentsJoinedByString:@"\r\n"]];
    }
    LKRTCSessionDescription *held = [[LKRTCSessionDescription alloc] initWithType:realOffer.type
        sdp:[heldSections componentsJoinedByString:@"\r\nm="]];
    __block BOOL applied = NO;
    __block NSError *applyError;
    [subscriber setRemoteDescription:held completionHandler:^(NSError *err) { applyError = err; applied = YES; }];
    Require(WaitUntil(5, ^BOOL { return applied; }) && !applyError, @"reserve receiver in native inactive offer");
    for (LKRTCRtpTransceiver *t in subscriber.transceivers) {
        if (![t.mid isEqual:mid]) continue;
        Require((!probe.receiver && !previousReceiverId) || [probe.receiver.receiverId isEqual:previousReceiverId],
                @"no new active track from reservation");
        if (whileHeld) whileHeld();
        *cryptor = [[LKRTCFrameCryptor alloc] initWithFactory:factory rtpReceiver:t.receiver
            participantId:@"receiver" algorithm:LKRTCCryptorAlgorithmAesGcm keyProvider:key];
        Require(*cryptor != nil, @"receiver cryptor before active description");
        (*cryptor).delegate = probe;
        (*cryptor).enabled = YES;
        return;
    }
    Require(NO, @"receiver missing after reservation");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        Require(argc == 3 && (!strcmp(argv[1], "match") || !strcmp(argv[1], "mismatch")), @"use match or mismatch, then h264 or vp8");
        BOOL match = !strcmp(argv[1], "match");
        LKRTCInitializeSSL();
        Probe *probe = [Probe new];
        LKRTCDefaultVideoEncoderFactory *encoders = [LKRTCDefaultVideoEncoderFactory new];
        NSString *codec = [[NSString stringWithUTF8String:argv[2]] uppercaseString];
        encoders.preferredCodec = [[LKRTCDefaultVideoEncoderFactory supportedCodecs] filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"name ==[c] %@", codec]].firstObject;
        Require(encoders.preferredCodec != nil, @"requested encoder available");
        LKRTCPeerConnectionFactory *factory = [[LKRTCPeerConnectionFactory alloc]
            initWithEncoderFactory:encoders decoderFactory:[LKRTCDefaultVideoDecoderFactory new]];
        LKRTCConfiguration *config = [LKRTCConfiguration new];
        config.sdpSemantics = LKRTCSdpSemanticsUnifiedPlan;
        LKRTCMediaConstraints *constraints = [[LKRTCMediaConstraints alloc] initWithMandatoryConstraints:nil optionalConstraints:nil];
        LKRTCPeerConnection *publisher = [factory peerConnectionWithConfiguration:config constraints:constraints delegate:probe];
        LKRTCPeerConnection *subscriber = [factory peerConnectionWithConfiguration:config constraints:constraints delegate:probe];
        LKRTCVideoSource *source = factory.videoSource;
        LKRTCVideoCapturer *capturer = [[LKRTCVideoCapturer alloc] initWithDelegate:source];
        LKRTCVideoTrack *camera = [factory videoTrackWithSource:source trackId:@"synthetic-camera"];
        LKRTCRtpTransceiverInit *inactive = [LKRTCRtpTransceiverInit new];
        inactive.direction = LKRTCRtpTransceiverDirectionInactive;
        LKRTCRtpTransceiver *video = [publisher addTransceiverWithTrack:camera init:inactive];
        Require(video.sender.track != nil && video.direction == LKRTCRtpTransceiverDirectionInactive, @"inactive real track");

        // A different m-line negotiates while the video's cryptor is deliberately held.
        // Using receive-only audio keeps this synthetic test independent of a microphone.
        LKRTCRtpTransceiverInit *receiveAudio = [LKRTCRtpTransceiverInit new];
        receiveAudio.direction = LKRTCRtpTransceiverDirectionRecvOnly;
        Require([publisher addTransceiverOfType:LKRTCRtpMediaTypeAudio init:receiveAudio] != nil, @"independent audio transceiver");
        Signal(publisher, subscriber, constraints, YES);
        Signal(subscriber, publisher, constraints, NO);
        Require(WaitUntil(15, ^BOOL { return publisher.connectionState == LKRTCPeerConnectionStateConnected; }),
                @"ICE/DTLS connection while cryptor is held");
        LKRTCRtpTransceiverDirection negotiated;
        Require([video currentDirection:&negotiated] && negotiated == LKRTCRtpTransceiverDirectionInactive,
                @"inactive video negotiated alongside audio");
        SendFrames(source, capturer, 20);
        Require(SentPackets(publisher, video.sender) == 0, @"no video RTP before sender cryptor readiness");

        LKRTCFrameCryptor *encoder = [[LKRTCFrameCryptor alloc] initWithFactory:factory rtpSender:video.sender
            participantId:@"caller" algorithm:LKRTCCryptorAlgorithmAesGcm keyProvider:Key(@"public test key")];
        Require(encoder != nil, @"sender cryptor");
        encoder.enabled = YES;
        NSError *directionError = nil;
        [video setDirection:LKRTCRtpTransceiverDirectionSendOnly error:&directionError];
        Require(directionError == nil && video.direction == LKRTCRtpTransceiverDirectionSendOnly, @"activate protected video");
        LKRTCFrameCryptorKeyProvider *receiveKey = Key(match ? @"public test key" : @"different test key");
        LKRTCFrameCryptor *decoder = nil;
        // Generate the offer once on the publisher. Reserve and protect the receiver
        // locally, then apply the original SDP. No intermediate SDP is signaled.
        __block LKRTCSessionDescription *offer;
        [publisher offerForConstraints:constraints completionHandler:^(LKRTCSessionDescription *o, NSError *e) { offer = o; }];
        Require(WaitUntil(5, ^BOOL { return offer != nil; }), @"create active offer");
        __block BOOL localSet = NO;
        [publisher setLocalDescription:offer completionHandler:^(NSError *e) { localSet = !e; }];
        Require(WaitUntil(5, ^BOOL { return localSet; }), @"set active offer locally");
        StageNewVideoReceiver(subscriber, publisher.localDescription, video.mid, receiveKey, probe, nil, factory, &decoder);
        __block BOOL remoteSet = NO;
        [subscriber setRemoteDescription:publisher.localDescription completionHandler:^(NSError *e) { remoteSet = !e; }];
        Require(WaitUntil(5, ^BOOL { return remoteSet; }), @"set original offer after protection");
        Signal(subscriber, publisher, constraints, NO);
        Require(WaitUntil(5, ^BOOL { return probe.receiver != nil; }) && !probe.receiver.track.isEnabled,
                @"receiver gated at native track event");
        LKRTCVideoTrack *track = (LKRTCVideoTrack *)probe.receiver.track;
        [track addRenderer:probe];
        SendFrames(source, capturer, 20);
        Require(probe.decodedPatterns == 0, @"gated receiver must deliver no source pixels");
        track.isEnabled = YES;
        SendFrames(source, capturer, 100);
        Require(SentPackets(publisher, video.sender) > 0, @"live encrypted video RTP");
        Require(match ? probe.decodedPatterns > 0 : (probe.decodedPatterns == 0 && probe.decryptFailed),
                @"decoded output and decrypt state must match the key scenario");
        printf("M150 %s protected video frames=%lu decryptionError=%d beforeSenderReadyRtp=0 beforeReceiverReady=0\n",
               argv[1], (unsigned long)probe.decodedPatterns, probe.decryptFailed);
        if (!match) {
            [receiveKey setSharedKey:[@"public test key" dataUsingEncoding:NSUTF8StringEncoding] withIndex:0];
            SendFrames(source, capturer, 100);
            Require(probe.decodedPatterns > 0, @"subsequent correct key recovers existing receiver");
            printf("corrected key decoded frames=%lu\n", (unsigned long)probe.decodedPatterns);
        }
        if (match) {
            // Introduce a new video receiver while the original actively renders.
            LKRTCVideoSource *secondSource = factory.videoSource;
            LKRTCVideoCapturer *secondCapture = [[LKRTCVideoCapturer alloc] initWithDelegate:secondSource];
            LKRTCVideoTrack *secondCamera = [factory videoTrackWithSource:secondSource trackId:@"second-camera"];
            LKRTCRtpTransceiver *second = [publisher addTransceiverWithTrack:secondCamera init:inactive];
            LKRTCFrameCryptor *enc2 = [[LKRTCFrameCryptor alloc] initWithFactory:factory rtpSender:second.sender
                participantId:@"second-caller" algorithm:LKRTCCryptorAlgorithmAesGcm keyProvider:Key(@"public test key")];
            Require(enc2 != nil, @"protect second sender");
            enc2.enabled = YES;
            [second setDirection:LKRTCRtpTransceiverDirectionSendOnly error:&directionError];
            Require(!directionError, @"activate second sender");
            offer = nil;
            [publisher offerForConstraints:constraints completionHandler:^(LKRTCSessionDescription *o, NSError *e) { offer = o; }];
            Require(WaitUntil(5, ^BOOL { return offer != nil; }), @"create offer for new MID");
            localSet = NO;
            [publisher setLocalDescription:offer completionHandler:^(NSError *e) { localSet = !e; }];
            Require(WaitUntil(5, ^BOOL { return localSet; }), @"local offer for new MID");
            LKRTCFrameCryptor *dec2 = nil;
            NSUInteger before = probe.decodedPatterns;
            StageNewVideoReceiver(subscriber, publisher.localDescription, second.mid, receiveKey, probe, ^{
                SendFrames(source, capturer, 20);
                Require(probe.decodedPatterns > before, @"existing receiver continues rendering during reservation");
            }, factory, &dec2);
            remoteSet = NO;
            [subscriber setRemoteDescription:publisher.localDescription completionHandler:^(NSError *e) { remoteSet = !e; }];
            Require(WaitUntil(5, ^BOOL { return remoteSet; }), @"apply original offer for second MID");
            Signal(subscriber, publisher, constraints, NO);
            LKRTCVideoTrack *secondTrack = (LKRTCVideoTrack *)probe.receiver.track;
            Require(!secondTrack.isEnabled && ![secondTrack.trackId isEqual:track.trackId], @"new track gated");
            Probe *secondSink = [Probe new];
            [secondTrack addRenderer:secondSink];
            secondTrack.isEnabled = YES;
            SendFrames(secondSource, secondCapture, 40);
            Require(secondSink.decodedPatterns > 0, @"existing and new encrypted subscriptions coexist");

            NSString *retainedReceiverId = probe.receiver.receiverId;
            [second setDirection:LKRTCRtpTransceiverDirectionInactive error:&directionError];
            Require(!directionError, @"deactivate second sender");
            Signal(publisher, subscriber, constraints, YES);
            Signal(subscriber, publisher, constraints, NO);
            LKRTCVideoTrack *replacement = [factory videoTrackWithSource:secondSource trackId:@"replacement-camera"];
            second.sender.track = replacement;
            [second setDirection:LKRTCRtpTransceiverDirectionSendOnly error:&directionError];
            Require(!directionError, @"re-enable replaced sender track");
            Signal(publisher, subscriber, constraints, YES);
            Signal(subscriber, publisher, constraints, NO);
            Require([probe.receiver.receiverId isEqual:retainedReceiverId] && !secondTrack.isEnabled, @"reuse existing receiver and regate playout");
            secondTrack.isEnabled = YES;
            before = secondSink.decodedPatterns;
            SendFrames(secondSource, secondCapture, 40);
            Require(secondSink.decodedPatterns > before, @"same receiver decrypts replacement track");
            printf("new MID rendered with active subscription; reused receiver decoded %lu replacement frames\n",
                   (unsigned long)(secondSink.decodedPatterns - before));
            [secondTrack removeRenderer:secondSink];
            (void)enc2.enabled;
            (void)dec2.enabled;
        }
        [publisher close];
        [subscriber close];
        [track removeRenderer:probe];
        // Ensure the cryptors are retained through all frames, including optimized builds.
        (void)encoder.enabled;
        (void)decoder.enabled;
    }
    return 0;
}
