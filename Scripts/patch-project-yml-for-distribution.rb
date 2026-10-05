#!/usr/bin/env ruby
# frozen_string_literal: true

# Scope App Store signing to PrivateAgentApp only.
# SwiftPM package products (FlashMoEVendor, TurboQuantMetal, …) cannot use a
# manual provisioning profile. Those inherit project-level Automatic signing.
# Reads APPLE_TEAM_ID, PROFILE_NAME, IOS_BUNDLE_ID, BUILD_NUMBER, MARKETING_VERSION.

require "fileutils"
require "yaml"

required = %w[APPLE_TEAM_ID PROFILE_NAME IOS_BUNDLE_ID BUILD_NUMBER MARKETING_VERSION]
missing = required.select { |name| ENV[name].to_s.empty? }
unless missing.empty?
  warn "::error::Cannot patch project.yml; missing env: #{missing.join(', ')}"
  exit 1
end

team = ENV.fetch("APPLE_TEAM_ID")
profile = ENV.fetch("PROFILE_NAME")
bundle = ENV.fetch("IOS_BUNDLE_ID")
build = ENV.fetch("BUILD_NUMBER")
marketing = ENV.fetch("MARKETING_VERSION")

path = "project.yml"
data = YAML.load_file(path)
targets = data.fetch("targets")
app = targets.fetch("PrivateAgentApp")

extension_types = %w[app-extension watchkit2-extension tv-extension]
extensions = targets.select { |_name, spec| extension_types.include?(spec["type"].to_s) }
unless extensions.empty?
  names = extensions.keys.join(", ")
  warn "::error::App extension targets found (#{names}). The App Store profile only covers #{bundle}. Each extension needs its own bundle id and provisioning profile before TestFlight can archive."
  exit 1
end

FileUtils.mkdir_p("Configs")
File.write(
  "Configs/ci-packages.xcconfig",
  <<~XCCONFIG
    // Project-level. Inherited by SwiftPM package products / resource bundles.
    // Do not put PROVISIONING_PROFILE_SPECIFIER here.
    CODE_SIGN_STYLE = Automatic
    PROVISIONING_PROFILE_SPECIFIER =
    CODE_SIGN_IDENTITY =
  XCCONFIG
)
File.write(
  "Configs/ci-app-release.xcconfig",
  <<~XCCONFIG
    // PrivateAgentApp Release only. Not applied to package targets.
    CODE_SIGN_STYLE = Manual
    CODE_SIGN_IDENTITY = Apple Distribution
    DEVELOPMENT_TEAM = #{team}
    PROVISIONING_PROFILE_SPECIFIER = #{profile}
    PRODUCT_BUNDLE_IDENTIFIER = #{bundle}
    PRODUCT_NAME = Str8ZeRO
    CURRENT_PROJECT_VERSION = #{build}
    MARKETING_VERSION = #{marketing}
  XCCONFIG
)

data["configFiles"] = {
  "Debug" => "Configs/ci-packages.xcconfig",
  "Release" => "Configs/ci-packages.xcconfig"
}

project_base = ((data["settings"] ||= {})["base"] ||= {})
project_base["CODE_SIGN_STYLE"] = "Automatic"
project_base.delete("PROVISIONING_PROFILE_SPECIFIER")
project_base.delete("CODE_SIGN_IDENTITY")
project_base.delete("DEVELOPMENT_TEAM")

app["configFiles"] = { "Release" => "Configs/ci-app-release.xcconfig" }
app["settings"] ||= {}
app["settings"]["base"] ||= {}
app["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"] = bundle
app["settings"]["base"]["PRODUCT_NAME"] = "Str8ZeRO"
app["settings"]["base"]["CURRENT_PROJECT_VERSION"] = build
app["settings"]["base"]["MARKETING_VERSION"] = marketing
app["settings"]["configs"] ||= {}
app["settings"]["configs"]["Release"] = {
  "CODE_SIGN_STYLE" => "Manual",
  "CODE_SIGN_IDENTITY" => "Apple Distribution",
  "DEVELOPMENT_TEAM" => team,
  "PROVISIONING_PROFILE_SPECIFIER" => profile,
  "PRODUCT_BUNDLE_IDENTIFIER" => bundle,
  "PRODUCT_NAME" => "Str8ZeRO",
  "CURRENT_PROJECT_VERSION" => build,
  "MARKETING_VERSION" => marketing
}

File.write(path, data.to_yaml)

puts "Scoped Apple Distribution to PrivateAgentApp Release only."
puts "Export mapping: #{bundle} -> #{profile} (team #{team})"
puts "No app-extension targets in project.yml."
