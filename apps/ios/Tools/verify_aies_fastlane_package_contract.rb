#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "shellwords"
require "tmpdir"
require "fastlane"
require "gym"

EXPECTED_FASTLANE_VERSION = "2.228.0"
PACKAGE_FLAGS = {
  "-disableAutomaticPackageResolution" => nil,
  "-onlyUsePackageVersionsFromResolvedFile" => nil,
  "-skipPackageUpdates" => nil,
  "-disablePackageRepositoryCache" => nil,
  "-clonedSourcePackagesDirPath" => :source_packages,
  "-packageCachePath" => :package_cache
}.freeze

options = {}
OptionParser.new do |parser|
  parser.on("--project PATH") { |value| options[:project] = File.expand_path(value) }
  parser.on("--source-packages PATH") do |value|
    options[:source_packages] = File.expand_path(value)
  end
  parser.on("--package-cache PATH") do |value|
    options[:package_cache] = File.expand_path(value)
  end
  parser.on("--output PATH") { |value| options[:output] = File.expand_path(value) }
end.parse!

missing_options = %i[project source_packages package_cache output].reject do |key|
  value = options[key]
  value.is_a?(String) && !value.empty?
end
abort("missing required options: #{missing_options.join(', ')}") unless missing_options.empty?
abort("unexpected Fastlane version: #{Fastlane::VERSION}") unless Fastlane::VERSION == EXPECTED_FASTLANE_VERSION
abort("project does not exist: #{options[:project]}") unless File.directory?(options[:project])

{
  "GYM_SKIP_PACKAGE_DEPENDENCIES_RESOLUTION" => "true",
  "GYM_DISABLE_PACKAGE_AUTOMATIC_UPDATES" => "true",
  "GYM_CLONED_SOURCE_PACKAGES_PATH" => options[:source_packages]
}.each do |key, expected|
  abort("#{key} does not match shared package preparation") unless ENV[key] == expected
end

xcodebuild_command = ENV.fetch("GYM_XCODE_BUILD_COMMAND", "")
abort("GYM_XCODE_BUILD_COMMAND contains a newline") if xcodebuild_command.match?(/[\r\n\0]/)

Dir.mktmpdir("aies-fastlane-package-contract") do |temporary|
  config = FastlaneCore::Configuration.create(
    Gym::Options.available_options,
    {
      project: options[:project],
      scheme: "OpenClaw",
      configuration: "Release",
      destination: "generic/platform=iOS",
      output_directory: temporary,
      output_name: "OpenClaw",
      disable_xcpretty: true,
      skip_package_ipa: true
    }
  )
  Gym.config = config
  Gym.project = FastlaneCore::Project.new(config)

  archive_parts = Gym::BuildCommandGenerator.generate.map(&:to_s)
  archive_argv = Shellwords.split(archive_parts.join(" "))
  PACKAGE_FLAGS.each do |flag, value_key|
    positions = archive_argv.each_index.select { |index| archive_argv[index] == flag }
    abort("rendered archive command must contain #{flag} exactly once") unless positions.length == 1
    next if value_key.nil?

    observed = archive_argv[positions.first + 1]
    abort("rendered archive command has wrong value for #{flag}") unless observed == options[value_key]
  end
  abort("Gym must skip its separate package resolution") unless config[:skip_package_dependencies_resolution] == true

  export_parts = Gym::PackageCommandGenerator.generate.map(&:to_s)
  export_argv = Shellwords.split(export_parts.join(" "))
  abort("rendered export command is missing -exportArchive") unless export_argv.include?("-exportArchive")
  contaminated = PACKAGE_FLAGS.keys.select { |flag| export_argv.include?(flag) }
  abort("package flags contaminated export command: #{contaminated.join(', ')}") unless contaminated.empty?

  report = {
    schema: "aies.ios.fastlane-package-contract.v1",
    status: "verified",
    fastlaneVersion: Fastlane::VERSION,
    project: options[:project],
    sourcePackages: options[:source_packages],
    packageCache: options[:package_cache],
    archiveCommand: archive_parts.join(" "),
    archivePackageFlagCounts: PACKAGE_FLAGS.to_h do |flag, _|
      [flag, archive_argv.count(flag)]
    end,
    exportCommand: export_parts.join(" "),
    exportPackageFlags: contaminated,
    separateGymResolutionSkipped: true
  }
  output = Pathname.new(options[:output])
  FileUtils.mkdir_p(output.dirname)
  output.write(JSON.pretty_generate(report) + "\n")
  puts(JSON.pretty_generate(report))
end
