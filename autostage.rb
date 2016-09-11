#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'set'

Kerbal.thread 'autostage' do
  loop do
    current_stage = @vessel.control.current_stage
    next_stage = current_stage - 1
    next_parts = @vessel.parts.in_stage(next_stage)

    if next_parts.any? { |p| p.parachute || realchute(p) }
      puts "Autostage: Stage #{next_stage} contains parachutes."
      break
    end

    next_engines = next_parts.map(&:engine).compact
    next_decouplers = next_parts.map(&:decoupler).compact

    if next_engines.empty?
      found_engine = false
      (next_stage - 1).downto(0).each do |stage|
        if @vessel.parts.in_stage(stage).any?(&:engine)
          found_engine = true
          break
        end
      end

      if !found_engine
        puts "Autostage: No engines above stage #{current_stage}."
        break
      end
    end

    if next_decouplers.empty?
      puts "Autostage: Stage #{next_stage} contains only engines."
    else
      watch_engines = next_decouplers.map do |decoupler|
        parts_below(decoupler.part).map { |p| p.engine }.compact
      end.flatten(1).to_set

      last_count = nil
      loop do
        count = watch_engines.count { |e| e.has_fuel }
        puts "Autostage: Stage #{next_stage} is carrying #{count} engines with fuel remaining." if count != last_count
        break if count <= 0
        last_count = count
        sleep(0.2)
      end
    end

    puts "Autostage: Activating stage #{next_stage}."
    @control.activate_next_stage
    sleep(0.5)
  end

  puts "Autostage: Exiting."
end

Kerbal.run
