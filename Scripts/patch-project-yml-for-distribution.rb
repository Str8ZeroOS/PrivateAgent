#!/usr/bin/env ruby
# frozen_string_literal: true

# Stamp PrivateAgentApp with manual App Store signing and the release versions.
# Reads APPLE_TEAM_ID, PROFILE_NAME, IOS_BUNDLE_ID, BUILD_NUMBER, MARKETING_VERSION.

require "yaml"

required = %w[APPLE_TEAM_ID PROFILE_NAME IOS_BUNDLE_ID BUILD_NUMBER MARKETING_VERSION]
missing = required.select { |name| ENV[name].to_s.empty? }
unless missing.empty?
  warn "::error::Cannot patch project.yml; missing env: #{missing.join(', ')}"
  exit 1
end

path = "project.yml"
data = YAML.load_file(path)
target = data.fetch("targets").fetch("PrivateAgentApp")
target["settings"] ||= {}
target["settings"]["base"] ||= {}
target["settings"]["base"].merge!(
  "CODE_SIGN_STYLE" => "Manual",
  "CODE_SIGN_IDENTITY" => "Apple Distribution",
  "DEVELOPMENT_TEAM" => ENV.fetch("APPLE_TEAM_ID"),
  "PROVISIONING_PROFILE_SPECIFIER" => ENV.fetch("PROFILE_NAME"),
  "PRODUCT_BUNDLE_IDENTIFIER" => ENV.fetch("IOS_BUNDLE_ID"),
  "CURRENT_PROJECT_VERSION" => ENV.fetch("BUILD_NUMBER"),
  "MARKETING_VERSION" => ENV.fetch("MARKETING_VERSION")
)
File.write(path, data.to_yaml)
puts "Patched #{path} for Apple Distribution #{ENV.fetch('IOS_BUNDLE_ID')} #{ENV.fetch('MARKETING_VERSION')} (#{ENV.fetch('BUILD_NUMBER')})"
