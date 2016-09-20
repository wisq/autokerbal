#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

Kerbal.thread 'test', paused: false do
  @autopilot.target_pitch = 90
  @autopilot.engage

  @control.throttle = 0.0
  sleep(0.5)
  puts "Launching ..."
  @control.activate_next_stage
  sleep(1)

  flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  target_speed = 10.0
  gravity = @vessel.orbit.body.surface_gravity

  with_stream(@vessel.mass_stream) do |mass_stream|
    with_stream(@vessel.available_thrust_stream) do |thrust_stream|
      with_stream(flight.speed_stream) do |speed_stream|
        loop do
          mass = mass_stream.get
          thrust = thrust_stream.get
          speed = speed_stream.get

          @control.throttle = desired_throttle(speed, target_speed, mass, thrust, gravity)
          sleep(0.01)
        end
      end
    end
  end
end

def desired_throttle(current_speed, desired_speed, vessel_mass, vessel_thrust, surface_gravity)
  desired_acceleration = desired_speed - current_speed
  total_acceleration = surface_gravity + desired_acceleration
  throttle = total_acceleration / (@vessel.available_thrust / @vessel.mass); p throttle; sleep(0.01)
  return throttle
end

Kerbal.run
