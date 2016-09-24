#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

Kerbal.thread 'magno' do
  modules = {}
  if telescope = @vessel.parts.with_name('dmUSScope').first
    mod = telescope.modules.select { |m| m.name == 'DMModuleScienceAnimate' }.first
    modules[mod] = 'Log Visual Observations'
  end

  with_stream(@space_center.warp_rate_stream) do |warp_rate_stream|
    loop do
      do_science(modules) if warp_rate_stream.get == 1.0
      sleep(0.1)
    end
  end
end

def do_science(modules)
  modules.each do |mod, event|
    mod.trigger_event(event) if mod.has_event(event)
  end
end

Kerbal.run
