# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'ship_it/version'

Gem::Specification.new do |spec|
  spec.name          = "ship_it"
  spec.version       = ShipIt::VERSION
  spec.authors       = ["Boris Peterbarg"]
  spec.email         = ["boris@seekingalpha.com"]

  spec.summary       = "Deploy using CI."
  spec.description   = "Helper tools to deploy using CI."

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "rake", ">= 10.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "simplecov", "~> 0.10"

  spec.add_dependency "csv"
end
