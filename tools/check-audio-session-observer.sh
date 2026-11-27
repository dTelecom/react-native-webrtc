#!/usr/bin/env bash
set -euo pipefail

# Pass a public Rooms example checkout with its React Native 0.86+ CocoaPods installed.
# The optional second argument tests a packed bridge installed in another checkout.
consumer=$(cd "${1:?supply the installed public Rooms example root}" && pwd)
tools=$(cd "$(dirname "$0")" && pwd)
bridge=${2:-"$tools/.."}
native="$bridge/ios/RCTWebRTC"
pods="$consumer/ios/Pods"
slice=ios-arm64_x86_64-maccatalyst
react="$pods/React-Core-prebuilt/React.xcframework/$slice/React.framework/Headers"
webrtc="$pods/LiveKitWebRTC/LiveKitWebRTC.xcframework/$slice"
sdk=$(xcrun --sdk macosx --show-sdk-path)

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
# The CocoaPods Catalyst slice is unsigned. macOS requires an executable signature.
# Sign only the throwaway copy and leave the consumer's installed framework intact.
ditto "$webrtc/LiveKitWebRTC.framework" "$build/LiveKitWebRTC.framework"
codesign --force --sign - --timestamp=none "$build/LiveKitWebRTC.framework"
# Disable JS logging only. The observer and its actual React/WebRTC headers are compiled intact.
xcrun --sdk macosx clang -fobjc-arc -fmodules -target "$(uname -m)-apple-ios15.0-macabi" \
  -DRCTLOG_ENABLED=0 -isystem "$sdk/System/iOSSupport/usr/include" \
  -F"$sdk/System/iOSSupport/System/Library/Frameworks" -F"$webrtc" \
  -I"$native" -isystem "$react" -isystem "$react/React_Core" -isystem "$react/Yoga" \
  -framework Foundation -framework AVFAudio -framework LiveKitWebRTC \
  -Xlinker -rpath -Xlinker "$build" \
  "$tools/audio-session-observer.test.m" "$native/LKRNAudioDeviceModuleObserver.m" \
  -o "$build/audio-session-observer"
"$build/audio-session-observer"
