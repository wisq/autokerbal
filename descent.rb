#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'set'

PARACHUTE_MAX_SPEED = 300  # deploy chutes when under 300 m/s
PARACHUTE_MAX_ALTITUDE = 10000  # ... and under 10,000 m
PARACHUTE_MIN_ALTITUDE = 3000   # ignore speed if below 3000 m
PARACHUTE_VIA_STAGE = false  # use this for parachute test contracts

Kerbal.thread 'descent_reentry' do
  body = @vessel.orbit.body
  flight = @vessel.flight(body.reference_frame)
  atmosphere_depth = body.atmosphere_depth

  puts "Waiting for atmospheric reentry ..."
  until flight.mean_altitude < atmosphere_depth
    sleep(1)
  end
  Kerbal.start_thread('descent')
end

Kerbal.thread 'descent', paused: true do
  flight = @vessel.flight(@vessel.orbit.body.reference_frame)

  dewarp

  puts "Beginning descent procedures."
  @control.throttle = 0
  sleep(0.5)

  puts "Decoupling ..."
  decouplers = @vessel.parts.modules_with_name('ModuleDecouple')
  decouplers.sort_by { |m| m.part.stage }.each do |mod|
    if mod.has_event('Decouple')
      puts "Decoupling: #{mod.part.title}"
      mod.trigger_event('Decouple')
      sleep(0.2)
    end
  end

  puts "Turning to surface retrograde ..."
  @autopilot.reference_frame = @vessel.surface_velocity_reference_frame
  @autopilot.target_direction = [0,-1,0]
  @autopilot.engage

  with_stream(flight.mean_altitude_stream) do |alt_stream|
    with_stream(flight.speed_stream) do |speed|
      puts "Waiting for parachute targets ..."
      loop do
        altitude = alt_stream.get

        if altitude < PARACHUTE_MAX_ALTITUDE && speed.get < PARACHUTE_MAX_SPEED
          puts "Parachute targets achieved."
          break
        elsif altitude < PARACHUTE_MIN_ALTITUDE
          puts "Speed too high!  Deploying chutes anyway."
          break
        else
          sleep(0.1)
        end
      end
    end
  end

  chutes = @vessel.parts.modules_with_name('RealChuteModule')
  unless PARACHUTE_VIA_STAGE
    chutes.each do |mod|
      if mod.has_event('Arm parachute')
        puts "Arming parachute: #{mod.part.title}"
        mod.trigger_event('Arm parachute')
      end
    end
  end

  until chutes.any? { |mod| mod.has_event('Cut chute') }
    @control.activate_next_stage if PARACHUTE_VIA_STAGE
    sleep(0.5)
  end

  puts "Parachutes deployed.  Disengaging autopilot."
  @autopilot.disengage
end

Kerbal.run
