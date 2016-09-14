#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

Kerbal.execute 'action' do
  action = ARGV.first
  modules = @vessel.parts.all.map do |part|
    part.modules.select { |mod| mod.has_event(action) }
  end.flatten(1)

  modules.each do |mod|
    puts "Executing #{action.inspect}: #{mod.part.title}"
    mod.trigger_event(action)
  end
end

Kerbal.run
