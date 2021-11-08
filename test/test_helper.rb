require 'bundler/setup'
require 'simplecov'
require 'minitest/autorun'
SimpleCov.start
Dir['test/helpers/*.rb'].each { |task| require task.split('/')[1..-1].join('/') }
