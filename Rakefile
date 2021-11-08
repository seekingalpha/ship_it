require "bundler/gem_tasks"
require 'rake/testtask'

namespace :test do
  Rake::TestTask.new(:base) do |t|
    t.libs << 'test'
    t.pattern = 'test/base/*_test.rb'
    t.verbose = false
  end

  Rake::TestTask.new(:lib) do |t|
    t.libs << 'test'
    t.pattern = 'test/lib/*_test.rb'
    t.verbose = false
  end

  Rake::TestTask.new(:integration) do |t|
    t.libs << 'test'
    t.pattern = 'test/integration/*_test.rb'
    t.verbose = false
  end

  task :all => ['test:base', 'test:lib', 'test:integration']
end

task :default => 'test:all'
