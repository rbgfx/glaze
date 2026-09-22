# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec) do |task|
  task.ruby_opts = %w[-I../tessel/lib -I../rlsl/lib -I../rbgl/lib -I../larb/lib -I../twiddle/lib -I../metaco/lib]
end

task default: :spec
task verify: :spec
