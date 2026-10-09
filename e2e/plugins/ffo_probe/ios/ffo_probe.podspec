#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint ffo_probe.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'ffo_probe'
  s.version          = '0.0.1'
  s.summary          = 'Test plugin for the flutter_flavor_overrides e2e suite.'
  s.description      = <<-DESC
Test plugin with native code for the flutter_flavor_overrides e2e suite.
                       DESC
  s.homepage         = 'https://github.com/mavoryl/flutter_flavors_override'
  s.license          = { :type => 'MIT' }
  s.author           = 'mavoryl'
  s.source           = { :path => '.' }
  s.source_files = 'ffo_probe/Sources/ffo_probe/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'ffo_probe_privacy' => ['ffo_probe/Sources/ffo_probe/PrivacyInfo.xcprivacy']}
end
