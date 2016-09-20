#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'rb-pid-controller'

Kerbal.thread 'test2', paused: true do
  @autopilot.target_pitch = 90
  @autopilot.engage

  puts "Launching ..."
  @control.activate_next_stage
  sleep(1)

  pid = PIDController::PID.new(1, 1, 1)
  pid.set_consign(10.0)

  flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  with_stream(flight.speed_stream) do |speed_stream|
    loop do
      sleep(0.01)

      speed = speed_stream.get
      output = (pid << speed)
      p [speed, output]

      @control.throttle = -(output / 100.0) if output.finite?
    end
  end
end

Kerbal.thread 'test', paused: false do
  @autopilot.target_pitch = 90
  @autopilot.engage

  puts "Launching ..."
  @control.activate_next_stage
  sleep(1)

  @space_center.physics_warp_factor = 3

  puts "Waiting for booster burnout."
  until @vessel.available_thrust == 0.0
    sleep(0.1)
  end

  @control.throttle = 0.0
  @control.activate_next_stage
  @control.activate_next_stage

  puts "Waiting for descent."
  flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  last_altitude = 0.0
  with_stream(flight.mean_altitude_stream) do |altitude_stream|
    loop do
      altitude = altitude_stream.get
      break if altitude < last_altitude
      last_altitude = altitude
      sleep(0.1)
    end
  end

  dewarp
  puts "Beginning descent control."
  @autopilot.reference_frame = @vessel.surface_velocity_reference_frame
  @autopilot.target_direction = [0, -1, 0]
  @autopilot.engage

  desired_ratio = 2.0
  waiting = true
  pid = nil
  last_altitude = flight.surface_altitude
  last_time = Time.now

  with_stream(flight.surface_altitude_stream) do |altitude_stream|
    loop do
      sleep(0.01)

      altitude = altitude_stream.get
      time = Time.now
      time_delta = time - last_time
      vertical_velocity = (last_altitude - altitude) / time_delta

      if vertical_velocity <= 0.0
        p vertical_velocity
        next
      end

      ratio = [50.0, altitude].max / (vertical_velocity**2)

      if waiting
        p [vertical_velocity, ratio]
        next unless ratio < desired_ratio
        puts "Initiating descent velocity control."
        pid = PIDController::PID.new(1, 1, 1)
        pid.set_consign(desired_ratio)
        waiting = false
      end

      output = (pid << ratio)
      p [ratio, output]

      @control.throttle = -(output / 100.0) if output.finite?
    end
  end
end

Kerbal.run
