#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the `dev` and `prod` flavors to the iOS project of a fixture app, the way
# `flutter build ios --flavor <name>` expects them:
#
# - build configurations Debug-<flavor>, Release-<flavor> and Profile-<flavor>,
#   copies of Debug, Release and Profile in the project and in every target;
# - a shared scheme <flavor>, a copy of Runner that uses those configurations.
#
# `dev` gets a `.dev` bundle identifier suffix, like the Android `dev`
# productFlavor gets `applicationIdSuffix = ".dev"`, so a build shows which
# flavor it is.
#
# Usage: ruby e2e/tool/add_ios_flavors.rb <app>/ios/Runner.xcodeproj
#
# Needs the `xcodeproj` gem (it ships with CocoaPods). Idempotent: existing
# configurations and schemes are left as they are. Run once per fixture app;
# the result is committed.

require 'fileutils'
require 'xcodeproj'

FLAVORS = { 'dev' => '.dev', 'prod' => '' }.freeze
MODES = %w[Debug Release Profile].freeze

project_path = ARGV.fetch(0) { abort 'usage: add_ios_flavors.rb <app>/ios/Runner.xcodeproj' }
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |target| target.name == 'Runner' } or abort 'no Runner target'
lists = [project.build_configuration_list] + project.targets.map(&:build_configuration_list)

FLAVORS.each do |flavor, bundle_id_suffix|
  MODES.each do |mode|
    name = "#{mode}-#{flavor}"
    lists.each do |list|
      next if list[name]

      source = list[mode] or abort "no #{mode} configuration in #{list}"
      copy = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
      copy.name = name
      copy.build_settings = Marshal.load(Marshal.dump(source.build_settings))
      copy.base_configuration_reference = source.base_configuration_reference
      if list.equal?(runner.build_configuration_list) && !bundle_id_suffix.empty?
        copy.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] += bundle_id_suffix
      end
      list.build_configurations << copy
    end
  end
end
project.save

# The scheme is copied as text: Flutter edits it later (Swift Package Manager
# pre-action) and matches on Xcode's own formatting, which a re-serialized XML
# would not keep.
schemes = File.join(project_path, 'xcshareddata', 'xcschemes')
runner_scheme = File.read(File.join(schemes, 'Runner.xcscheme'))
FLAVORS.each_key do |flavor|
  path = File.join(schemes, "#{flavor}.xcscheme")
  next if File.exist?(path)

  File.write(path, runner_scheme.gsub(/buildConfiguration = "(#{MODES.join('|')})"/) do
    %(buildConfiguration = "#{Regexp.last_match(1)}-#{flavor}")
  end)
end
