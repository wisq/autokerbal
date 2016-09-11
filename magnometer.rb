#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

Kerbal.thread 'magno' do
  part = @vessel.parts.with_name('dmmagBoom').first
  mod = part.modules.select { |m| m.name == 'DMModuleScienceAnimate' }.first

  if mod.has_event('Discard Magnetometer Data')
    raise "Magnometer already has data"
  end

  mod.trigger_event('Log Magnetometer Data')
  until mod.has_event('Discard Magnetometer Data')
    sleep(1)
  end
  mod.trigger_event('Toggle Magnetometer')
end

Kerbal.run
