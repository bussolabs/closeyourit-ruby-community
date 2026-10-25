# frozen_string_literal: true

require "json"
require "json_schemer"

module OpenDashboardContract
  ROOT = File.expand_path("../../contracts/open-dashboard", __dir__)
  DIR = File.join(ROOT, "v1")

  def self.json(relative) = JSON.parse(File.read(File.join(DIR, relative)))

  def self.validator
    schema = json("schema.json")
    JSONSchemer.schema({
      "$schema" => schema.fetch("$schema"),
      "$ref" => "#/$defs/report",
      "$defs" => schema.fetch("$defs")
    })
  end
end
