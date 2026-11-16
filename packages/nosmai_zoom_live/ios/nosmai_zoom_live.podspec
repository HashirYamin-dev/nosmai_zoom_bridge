Pod::Spec.new do |s|
  s.name             = 'nosmai_zoom_live'
  s.version          = '0.1.0'
  s.summary          = 'Livestream Nosmai-processed camera video through the Zoom Video SDK.'
  s.description      = <<-DESC
Feeds Nosmai's processed camera frames into a Zoom Video SDK external video source,
so Flutter apps can livestream Nosmai effects without native code.
                       DESC
  s.homepage         = 'https://nosmai.com'
  s.license          = { :type => 'Proprietary', :text => 'Nosmai and the Zoom Video SDK are governed by their own licenses.' }
  s.author           = { 'Nosmai' => 'admin@nosmai.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*.{h,m}'
  s.public_header_files = 'Classes/NosmaiZoomLivePlugin.h'
  s.resource_bundles = {
    'nosmai_zoom_live_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }

  s.dependency 'Flutter'
  # The Nosmai version is pinned by nosmai_effects_sdk; keep Zoom in step with android/build.gradle.
  s.dependency 'nosmai_effects_sdk'
  # ZoomVideoSDK.framework links util, zContext and ZoomTask at launch (dyld aborts without them).
  zoom_video_sdk_version = '2.6.15'
  %w[ZoomVideoSDK util zContext ZoomTask].each do |subspec|
    s.dependency "ZoomVideoSDK/#{subspec}", zoom_video_sdk_version
  end

  s.platform = :ios, '15.0'
  # ZoomVideoSDK is a static framework.
  s.static_framework = true
  s.frameworks = 'AVFoundation', 'CoreVideo', 'QuartzCore', 'UIKit'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64'
  }
end
