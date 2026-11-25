require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name                = 'dtelecom-react-native-webrtc'
  s.version             = package['version']
  s.summary             = package['description']
  s.homepage            = package['homepage']
  s.license             = package['license']
  s.author              = 'https://github.com/livekit/react-native-webrtc/graphs/contributors'
  s.source              = { :git => 'https://github.com/dTelecom/react-native-webrtc.git', :tag => s.version.to_s }
  s.requires_arc        = true

  s.platforms           = { :ios => '12.0', :osx => '10.13', :tvos => '16.0' }

  s.preserve_paths      = 'ios/**/*'
  s.source_files        = 'ios/**/*.{h,m}'
  s.libraries           = 'c', 'sqlite3', 'stdc++'
  s.framework           = 'AudioToolbox','AVFoundation', 'CoreAudio', 'CoreGraphics', 'CoreVideo', 'GLKit', 'VideoToolbox'
  s.dependency          'React-Core'
  s.dependency          'LiveKitWebRTC', '= 150.7871.04'
  
  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }

end
