#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'set'

MIN_CHARGE = 50  # percent
MAX_CHARGE = 90  # percent
CELL_INDEX = 0

Kerbal.thread 'fuelcell' do
  fuel_cell = @vessel.parts.resource_converters.
    select { |rc| rc.part.name =~ /\.Fuelcell$/ }.first
  part_title = fuel_cell.part.title
  resources = @vessel.resources

  active = fuel_cell.active(CELL_INDEX)
  loop do
    current_ec = resources.amount('ElectricCharge')
    max_ec = resources.max('ElectricCharge')
    percent = 100 * (current_ec / max_ec)

    if !active && percent < MIN_CHARGE
      new_active = true
    elsif active && percent >= MAX_CHARGE
      new_active = false
    else
      sleep_ut(5)
      next
    end

    puts "Electric charge: %.2f / %.2f (%d%%)" % [current_ec, max_ec, percent]
    if new_active
      puts "Starting: #{part_title}"
      fuel_cell.start(CELL_INDEX)
    else
      puts "Stopping: #{part_title}"
      fuel_cell.stop(CELL_INDEX)
    end
    active = new_active
  end
end

Kerbal.run
