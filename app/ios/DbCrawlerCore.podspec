#
# Links the Go core into the iOS app.
#
# The core is a *static* archive, and nothing in Swift or Objective-C
# references its symbols — Dart looks them up at runtime through
# DynamicLibrary.process(). A static archive only contributes the object files
# needed to resolve an undefined symbol, so without -force_load the linker
# drops the entire core and the app launches, then dies on the first lookup.
#
# The archives are produced by tool/build-core.sh, which must run before
# `pod install`.
#
# This deliberately does NOT use an xcframework. CocoaPods extracts xcframework
# slices in a build *script phase*, so the extracted .a does not exist at the
# point Xcode validates build inputs — and a -force_load pointing into
# PODS_XCFRAMEWORKS_BUILD_DIR fails with "Build input file cannot be found",
# which is exactly how the second release build died. Referencing the archives
# where they already sit in the source tree sidesteps the ordering entirely.
#
# Device and simulator cannot be merged with lipo: both are arm64, and only
# their platform differs. So each is kept separate and selected by SDK.
#
Pod::Spec.new do |s|
  s.name             = 'DbCrawlerCore'
  s.version          = '0.0.8'
  s.summary          = 'The Go database core behind DB Crawler.'
  s.description      = <<~DESC
    Connection handling, query execution, and schema introspection for
    SQL Server, PostgreSQL, MySQL, and SQLite, compiled from Go and reached
    over dart:ffi.
  DESC
  s.homepage         = 'https://github.com/Ark-Devs/DB-Crawler'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Ark Devs' => 'https://github.com/Ark-Devs' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'

  # Keep the archives in place without letting CocoaPods try to link them
  # itself — the -force_load flags below do the linking.
  s.preserve_paths = 'Frameworks/**/*'

  # The Go runtime's network stack calls into the system resolver.
  s.libraries = 'resolv'

  # Applied to the Runner target, which performs the final link. PODS_ROOT is
  # app/ios/Pods, so its parent is app/ios.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS[sdk=iphoneos*]' =>
      '$(inherited) -force_load "${PODS_ROOT}/../Frameworks/device/libdbcrawler.a"',
    'OTHER_LDFLAGS[sdk=iphonesimulator*]' =>
      '$(inherited) -force_load "${PODS_ROOT}/../Frameworks/simulator/libdbcrawler.a"',
  }

  # Nothing here is Swift or Objective-C — there is no module to build, only
  # an archive to link.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'NO' }
end
