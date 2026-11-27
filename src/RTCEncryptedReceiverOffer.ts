export interface EncryptedReceiverBinding {
    kind: string;
    publicationId?: string;
}

function audioPublicationId(section: string): string | undefined {
    // Unified Plan MSID is authoritative; older offers repeat it on their SSRCs.
    const media = Array.from(section.matchAll(/^a=msid:([^\r\n]+)\r?$/gm), match => match[1]);
    const values = media.length ? media
        : Array.from(section.matchAll(/^a=ssrc:\d+[ \t]+msid:([^\r\n]+)\r?$/gm), match => match[1]);
    const packed = new Set<string>();
    const trackIds = new Set<string>();

    for (const value of values) {
        const [ stream, track ] = value.trim().split(/\s+/);

        // dTelecom's PackStreamID uses "participant SID|track SID". The SDP track
        // token can refer to the receiver slot and survive replacement of its publisher.
        if (/^[^|\s]+\|[^\s]+$/.test(stream)) {
            packed.add(stream);
        }

        if (track) {
            trackIds.add(track);
        }
    }

    const ids = packed.size ? packed : trackIds;

    if (ids.size > 1) {
        throw new Error('Encrypted audio MID has conflicting publication identifiers');
    }

    return ids.values().next().value;
}

// Reserve new receivers and changed audio publications before the active offer.
export function reserveEncryptedReceiverMids(
    sdp: string,
    protectedMids: Map<string, EncryptedReceiverBinding>
): { reservation?: string, pending: Map<string, EncryptedReceiverBinding> } {
    const newline = sdp.includes('\r\n') ? '\r\n' : '\n';
    const sections = sdp.split(/(?=^m=)/m);
    const sessionDirection = sections[0]?.match(/^a=(?:sendrecv|sendonly|recvonly|inactive)\r?$/m)?.[0];
    const pending = new Map<string, EncryptedReceiverBinding>();
    const mids = new Set<string>();
    const staged = sections.map(section => {
        const media = /^m=(audio|video) (\d+)(?:\/\d+)? /u.exec(section);

        if (!media && /^m=(audio|video)\b/.test(section)) {
            throw new Error('Malformed encrypted RTP media section');
        }

        if (!media || (media[2] === '0' && !/^a=bundle-only\r?$/m.test(section))) {
            return section;
        }

        const midLines = section.match(/^a=mid:[^\r\n]*\r?$/gm) ?? [];
        const mid = midLines[0]?.slice(6).trim();

        if (midLines.length !== 1 || !mid || /\s/.test(mid) || mids.has(mid)) {
            throw new Error('Encrypted media offer requires unique RTP MIDs');
        }

        mids.add(mid);

        const directions = section.match(/^a=(?:sendrecv|sendonly|recvonly|inactive)\r?$/gm) ?? [];

        if (directions.length > 1) {
            throw new Error('Encrypted media section has conflicting directions');
        }

        const kind = media[1];
        const sending = !/^a=(?:inactive|recvonly)/.test(directions[0] ?? sessionDirection ?? '');
        const previous = protectedMids.get(mid);
        const publicationId = kind === 'audio' && sending ? audioPublicationId(section) : undefined;

        if (previous?.kind === kind && (!sending || previous.publicationId === publicationId)) {
            return section;
        }

        pending.set(mid, { kind, publicationId });

        if (directions.length) {
            return section.replace(/^a=(?:sendrecv|sendonly|recvonly|inactive)(?=\r?$)/m, 'a=inactive');
        }

        return section.replace(/^(m=[^\r\n]*)(\r?\n)/, (_line, mline, delimiter) =>
            mline + delimiter + 'a=inactive' + newline);
    });

    return { reservation: pending.size ? staged.join('') : undefined, pending };
}
