const assert = require('node:assert/strict');
const { test } = require('node:test');
const { reserveEncryptedReceiverMids } = require('../lib/commonjs/RTCEncryptedReceiverOffer');

const header = 'v=0\r\na=sendrecv\r\n';
const audio = 'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:a\r\na=sendonly\r\n';
const video = 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:v\r\na=msid:new stream\r\n';
const data = 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:d\r\n';
const stopped = 'm=video 0 UDP/TLS/RTP/SAVPF 96\r\na=mid:retired\r\n';

test('holds a new video MID, preserving active audio and data byte-for-byte', () => {
    const offer = header + audio + video + data + stopped;
    const { reservation, pending } = reserveEncryptedReceiverMids(offer, new Map([ [ 'a', { kind: 'audio' } ] ]));

    assert.deepEqual([ ...pending ], [ [ 'v', { kind: 'video', publicationId: undefined } ] ]);
    assert.equal(reservation, header + audio + video.replace('a=mid:v', 'a=inactive\r\na=mid:v') + data + stopped);
});

test('resubscription to a prepared receiver accepts the new MSID without a second reservation', () => {
    const { reservation, pending } = reserveEncryptedReceiverMids(
        header + video.replace('new stream', 'other replacement'), new Map([ [ 'v', { kind: 'video', publicationId: undefined } ] ])
    );

    assert.equal(reservation, undefined);
    assert.equal(pending.size, 0);
});

test('reserves bundled-only and changed-kind MIDs, including previously inactive media', () => {
    const bundled = video.replace('video 9', 'video 0').replace('a=mid:v', 'a=bundle-only\r\na=inactive\r\na=mid:v');
    const { reservation, pending } = reserveEncryptedReceiverMids(header + bundled, new Map([ [ 'v', { kind: 'audio' } ] ]));

    assert.equal(reservation, header + bundled);
    assert.deepEqual([ ...pending ], [ [ 'v', { kind: 'video', publicationId: undefined } ] ]);
});

test('rotates an occupied audio slot only when its publication changes', () => {
    const previous = new Map([ [ 'a', { kind: 'audio', publicationId: 'PA_first|TR_mic' } ],
        [ 'v', { kind: 'video' } ] ]);
    const same = audio + 'a=msid:PA_first|TR_mic local-track\r\n';
    const changes = same.replace('local-track', 'other-native-id') + 'a=ssrc:123 cname:new\r\n';
    const newAudio = same.replace('PA_first|TR_mic', 'PA_second|TR_mic');

    assert.equal(reserveEncryptedReceiverMids(header + changes, previous).reservation, undefined);
    for (const held of [ newAudio.replace('sendonly', 'inactive'), newAudio.replace('sendonly', 'recvonly') ]) {
        assert.equal(reserveEncryptedReceiverMids(header + held, previous).reservation, undefined);
    }
    assert.equal(reserveEncryptedReceiverMids('v=0\r\na=inactive\r\n' +
        newAudio.replace('a=sendonly\r\n', ''), previous).reservation, undefined);
    const { pending, reservation } = reserveEncryptedReceiverMids(header + newAudio + video + data, previous);

    assert.deepEqual([ ...pending ], [ [ 'a', { kind: 'audio', publicationId: 'PA_second|TR_mic' } ] ]);
    assert.equal(reservation, header + newAudio.replace('sendonly', 'inactive') + video + data);
});

test('legacy SSRC MSIDs track the publication independently of SSRC and packed mode', () => {
    const ssrc = 'a=ssrc:123 msid:PA_first TR_mic\r\n';
    const previous = new Map([ [ 'a', { kind: 'audio', publicationId: 'TR_mic' } ] ]);
    const parse = lines => reserveEncryptedReceiverMids(header + audio + lines, previous);

    assert.equal(parse(ssrc + ssrc.replace('123', '456')).reservation, undefined);
    assert.equal(parse(ssrc.replace('TR_mic', 'TR_screen')).pending.get('a').publicationId, 'TR_screen');
    assert.equal(parse(ssrc.replace('PA_first', 'PA_other|TR_other')).pending.get('a').publicationId, 'PA_other|TR_other');
    assert.throws(() => parse(ssrc + ssrc.replace('TR_mic', 'TR_other')), /conflicting publication/);
    assert.throws(() => parse('a=msid:PA_1|TR_1 slot\r\na=msid:PA_2|TR_2 slot\r\n'), /conflicting publication/);
});

test('rejects ambiguous or malformed new RTP sections before applying an active offer', () => {
    for (const invalid of [
        video.replace('a=mid:v\r\n', ''),
        video + video,
        video.replace('video 9 ', 'video NaN '),
        video.replace('a=mid:v', 'a=mid:v\r\na=mid:other'),
        video.replace('a=mid:v', 'a=mid:v\r\na=sendonly\r\na=inactive')
    ]) {
        assert.throws(() => reserveEncryptedReceiverMids(header + invalid, new Map()));
    }
});

test('answers wait for native encryption, and failed preparation cannot expose provisional SDP', async t => {
    const Module = require('node:module');
    const { EventEmitter } = require('node:events');
    const originalLoad = Module._load;
    const native = {
        peerConnectionInit: () => true,
        peerConnectionRequireEncryptedReceivers: () => true,
        peerConnectionCreateAnswer: t.mock.fn(async () => ({ sdpInfo: {}, transceiversInfo: [] })),
        peerConnectionSetLocalDescription: t.mock.fn(async () => ({ sdpInfo: {}, transceiversInfo: [] }))
    };
    const mockLoad = t.mock.method(Module, '_load', function(request, ...args) {
        if (request === 'react-native') return { NativeModules: { LKRNWebRTCModule: native }, NativeEventEmitter: EventEmitter };
        if (request === 'react-native/Libraries/vendor/emitter/EventEmitter') return EventEmitter;
        return originalLoad.call(this, request, ...args);
    });
    const PeerConnection = require('../lib/commonjs/RTCPeerConnection').default;

    const KeyProvider = require('../lib/commonjs/RTCKeyProvider').default;
    const provider = new KeyProvider('test-provider');

    native.keyProviderRestoreSharedKeyForParticipant = t.mock.fn(async ({ keyIndex }) => keyIndex === 0);
    assert.equal(await provider.restoreSharedKeyForParticipant('test-receiver'), true);
    assert.equal(await provider.restoreSharedKeyForParticipant('test-receiver', 1), false);
    assert.deepEqual(native.keyProviderRestoreSharedKeyForParticipant.mock.calls[0].arguments, [
        { keyProviderId: 'test-provider', participantId: 'test-receiver', keyIndex: 0 },
    ]);
    for (const bad of [ [ 'shared', 0 ], [ '', 0 ], [ 'test-receiver', -1 ], [ 'test-receiver', 1.5 ] ]) {
        await assert.rejects(provider.restoreSharedKeyForParticipant(...bad), /Invalid/);
    }
    assert.equal(native.keyProviderRestoreSharedKeyForParticipant.mock.callCount(), 2);

    mockLoad.mock.restore();
    for (const fail of [ false, true ]) {
        const pc = new PeerConnection();
        const remote = { type: 'offer', sdp: header + audio };
        const receiver = { track: { kind: 'audio' } };
        const applied = [];
        let prepared;
        const started = new Promise(resolve => { prepared = resolve; });
        let release;
        const waiting = new Promise((resolve, reject) => { release = fail ? () => reject(new Error('unavailable')) : resolve; });

        pc._applyRemoteDescription = async (description, reservationOnly) => {
            applied.push(description);
            if (reservationOnly) pc.getTransceivers = () => [ { mid: 'a', receiver, stopped: false } ];
            else pc.remoteDescription = description;
        };
        pc.prepareEncryptedReceivers(async candidate => {
            assert.equal(candidate, receiver);
            prepared();
            await waiting;
        });
        const setting = pc.setRemoteDescription(remote);
        await started;
        const answering = pc.createAnswer();
        const settingLocal = pc.setLocalDescription({ type: 'answer', sdp: '' });

        assert.equal(pc.remoteDescription, null);
        assert.equal(native.peerConnectionCreateAnswer.mock.callCount(), 0);
        assert.equal(native.peerConnectionSetLocalDescription.mock.callCount(), 0);
        assert.match(applied[0].sdp, /a=inactive/);
        if (fail) {
            const absent = [ setting, answering, settingLocal ].map(p => assert.rejects(p, /unavailable/));

            release();
            await Promise.all(absent);
            assert.equal(applied.length, 1);
            assert.equal(native.peerConnectionCreateAnswer.mock.callCount(), 0);
            assert.equal(native.peerConnectionSetLocalDescription.mock.callCount(), 0);
        } else {
            release();
            await Promise.all([ setting, answering, settingLocal ]);
            assert.equal(applied[1].sdp, remote.sdp);
            assert.equal(native.peerConnectionCreateAnswer.mock.callCount(), 1);
            assert.equal(native.peerConnectionSetLocalDescription.mock.callCount(), 1);
        }
        native.peerConnectionCreateAnswer.mock.resetCalls();
        native.peerConnectionSetLocalDescription.mock.resetCalls();
    }

    const pc = new PeerConnection();
    const receiver = { track: { kind: 'audio' } };
    const seen = [];
    const offer = pub => ({ type: 'offer', sdp: header + audio + `a=msid:${pub} slot\r\n` });
    const phases = [];
    let rejectNextActive = false;

    pc.getTransceivers = () => [ { mid: 'a', receiver, stopped: false } ];
    pc._applyRemoteDescription = async (description, reservationOnly) => {
        phases.push(reservationOnly ? 'reserve' : 'activate');
        if (!reservationOnly) {
            if (rejectNextActive) {
                rejectNextActive = false;
                throw new Error('native rejected offer');
            }
            pc.remoteDescription = description;
        }
    };
    pc.prepareEncryptedReceivers(async (candidate, publicationId) => {
        phases.push('prepare');
        assert.equal(candidate, receiver);
        seen.push(publicationId);
        if (publicationId === 'PA_3|TR_3') throw new Error('key unavailable');
    });
    const first = offer('PA_1|TR_1');
    const second = offer('PA_2|TR_2');
    await pc.setRemoteDescription(first);
    await pc.setRemoteDescription(first);
    assert.deepEqual(phases, [ 'reserve', 'prepare', 'activate', 'activate' ]);
    phases.length = 0;
    rejectNextActive = true;
    await assert.rejects(pc.setRemoteDescription(second), /native rejected/);
    assert.deepEqual(pc.remoteDescription, first);
    assert.deepEqual(phases, [ 'reserve', 'prepare', 'activate' ]);
    phases.length = 0;
    await pc.setRemoteDescription(second);
    assert.deepEqual(phases, [ 'activate' ]);
    phases.length = 0;
    await assert.rejects(pc.setRemoteDescription(offer('PA_3|TR_3')), /key unavailable/);
    assert.deepEqual(pc.remoteDescription, second);
    assert.deepEqual(phases, [ 'reserve', 'prepare' ]);
    phases.length = 0;
    await pc.setRemoteDescription(second);
    assert.deepEqual(phases, [ 'reserve', 'prepare', 'activate' ]);
    assert.deepEqual(seen, [ 'PA_1|TR_1', 'PA_2|TR_2', 'PA_3|TR_3', 'PA_2|TR_2' ]);
});
