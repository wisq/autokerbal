#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

Kerbal.execute 'target' do
  name = ARGV.first
  if body = @space_center.bodies[name]
    puts "Targeting body: #{body.name}"
    @space_center.target_body = body
  elsif vessel = @space_center.vessels.find { |v| v.name == name }
    puts "Targeting vessel: #{vessel.name}"
    @space_center.target_vessel = vessel
  else
    abort "Target not found: #{name}"
  end
end
