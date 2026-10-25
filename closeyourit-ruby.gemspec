# frozen_string_literal: true

require_relative "lib/closeyourit/version"

Gem::Specification.new do |spec|
  spec.name        = "closeyourit-ruby"
  spec.version     = CloseYourIt::VERSION
  spec.authors     = [ "Alessio Bussolari" ]
  spec.email       = [ "hello@bussolarialessio.me" ]

  spec.summary     = "Client di telemetria per CloseYourIt (errori + query/metodi lenti)."
  spec.description = "Gemma client che cattura eccezioni e le statistiche di query e metodi lenti " \
                     "e le invia, fire-and-forget, all'endpoint di ingest di CloseYourIt."
  spec.homepage    = "https://github.com/bussolabs/closeyourit-ruby-community"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 4.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage

  spec.files        = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "concurrent-ruby", "~> 1.3"
  # `logger` is no longer a default gem since Ruby 4.0: without declaring it, `require "logger"` (entry
  # point and log_broadcast) blows up in an app that installs only this gem. Found by the smoke install
  # on an isolated GEM_HOME (CYRB-13); in the development bundle other gems provide it, so it goes unnoticed.
  spec.add_dependency "logger", "~> 1.6"
end
