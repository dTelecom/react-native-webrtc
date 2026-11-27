# dTelecom React Native WebRTC

`@dtelecom/react-native-webrtc` is the native WebRTC bridge for the dTelecom React Native SDK on Android and iOS. The [released React Native SDK](https://www.npmjs.com/package/@dtelecom/react-native) pins the M150 bridge package and installs it automatically. App developers can start with the [Meet and Live example](https://github.com/dTelecom/client-sdk-react-native/tree/dtelecom-m150/example). The legacy 104.x line used by the public React Native 1.x SDK is available on the [v104.0 branch](https://github.com/dTelecom/react-native-webrtc/tree/v104.0).

## Development

Use Node from `.nvmrc`, then run `npm ci`, `npm run lint` and `npm pack`. Install the resulting tarball in a React Native app. Use React Native autolinking, then install the app’s CocoaPods dependencies for iOS. Install a single copy of the bridge in the app. The dTelecom and LiveKit M150 packages share native module names.

On macOS, run `bash tools/check-audio-session-observer.sh /path/to/client-sdk-react-native/example` after installing the example’s CocoaPods. This checks microphone activation, audio-session ownership and retries against the native observer.

### iOS CocoaPods sources

Add both sources at the top of the consuming app’s Podfile before running `pod install`. The LiveKit specs repository provides the pinned `LiveKitWebRTC` framework.

```ruby
source 'https://github.com/livekit/podspecs.git'
source 'https://cdn.cocoapods.org/'
```

## Android video tiles

`RTCView` uses a SurfaceView by default. Set `useTextureView` on Android for a video tile that needs to follow its parent’s rounded clipping or overlap another tile in the React Native view hierarchy.

```tsx
import { View } from 'react-native';
import { RTCView } from '@dtelecom/react-native-webrtc';

<View style={{ width: 120, height: 160, borderRadius: 12, overflow: 'hidden' }}>
  <RTCView
    streamURL={stream.toURL()}
    style={{ flex: 1 }}
    objectFit="cover"
    mirror={frontCamera}
    useTextureView
  />
</View>
```

## Upstream

The bridge is based on [LiveKit React Native WebRTC 150.2.0](https://github.com/livekit/react-native-webrtc/tree/dd84524980c6bb6253095f1b64cc16ddad85449c) and retains its MIT license and attributions. Android uses `io.github.webrtc-sdk:android-prefixed` and Apple uses the `LiveKitWebRTC` pod, both at 150.7871.04. The native frameworks perform TURN/TLS certificate verification.

[Android setup](./Documentation/AndroidInstallation.md) · [iOS setup](./Documentation/iOSInstallation.md) · [Bridge license](./LICENSE)
