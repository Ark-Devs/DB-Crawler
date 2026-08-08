#
# Links the Go core into the iOS app.
#
# The core is a *static* archive, and nothing in Swift or Objective-C
# references its symbols — Dart looks them up at runtime through
# DynamicLibrary.process(). A static archive only contributes the object files
# needed to resolve an undefined symbol, so without -force_load the linker
# would quite correctly drop the entire core and the app would launch, then
# fail on the first lookup with a symbol-not-found crash.
#
# The archive is produced by tool/build-core.sh, which must run before
# `pod install`.
#
Pod::Spec.new do |s|
  s.name             = 'DbCrawlerCore'
  s.version          = '0.0.1'
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

  s.vendored_frameworks = 'Frameworks/DbCrawlerCore.xcframework'

  # The Go runtime's network stack calls into the system resolver.
  s.libraries = 'resolv'

  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -force_load "$(PODS_XCFRAMEWORKS_BUILD_DIR)/DbCrawlerCore/libdbcrawler.a"',
  }

  # Nothing here is Swift or ObjC, so there is no module to build — only an
  # archive to link.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
