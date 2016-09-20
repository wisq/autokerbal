#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

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

  action = "Extend Stabilizers"
  @vessel.parts.with_name("MKS.LandingLeg").each do |part|
    part.modules.each do |mod|
      if mod.has_event(action)
        puts "Extending: #{part.title}"
        mod.trigger_event(action)
      end
    end
  end

  #flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  gravity = @vessel.orbit.body.surface_gravity
  time_to_land = 10.0
  minimum_speed = 5.0
  state = :suicide_burn

  minimum_altitude = time_to_land * minimum_speed

  with_stream(flight.speed_stream) do |speed_stream|
    puts "Waiting for initial descent."
    until speed_stream.get > minimum_speed*2
      sleep(0.01)
    end

    with_stream(@vessel.mass_stream) do |mass_stream|
      with_stream(@vessel.available_thrust_stream) do |thrust_stream|
        with_stream(flight.surface_altitude_stream) do |altitude_stream|
          loop do
            mass = mass_stream.get
            thrust = thrust_stream.get
            speed = speed_stream.get
            altitude = altitude_stream.get

            if state == :suicide_burn
              if speed <= minimum_speed
                puts "transition to final"
                state = :final
              else
                suicide_altitude = suicide_burn_altitude(speed, minimum_speed, mass, thrust, gravity)
                target_altitude = suicide_altitude + minimum_altitude
                throttle = if altitude < target_altitude then 1.0 else 0.0 end
                puts "delta to burn: #{altitude - target_altitude}"
                @control.throttle = throttle
              end
            elsif state == :final
              target_speed = altitude / time_to_land
              target_speed = minimum_speed if target_speed < minimum_speed
              @control.throttle = throttle = desired_throttle(speed, target_speed, mass, thrust, gravity)
              break if altitude < (minimum_speed / 2.0)
            else
              raise "invalid state: #{state}"
            end

            sleep(0.01)
          end

          @control.throttle = 0.0
          @autopilot.disengage
          puts "We landed!  Huzzah!"
        end
      end
    end
  end
end

def suicide_burn_altitude(current_speed, target_speed, vessel_mass, vessel_thrust, surface_gravity)
  ship_acceleration = vessel_thrust / vessel_mass
  net_acceleration = ship_acceleration - surface_gravity
  # This uses the acceleration formula:
  #   x = v*t + 0.5*a*t^2
  # where x is distance (m) (this will be our target altitude),
  # v is initial velocity (m/s) (we use our current velocity),
  # a is acceleration (m/s/s) (we use negative net acceleration),
  # t is time (s) (we use time needed to get to zero velocity).
  time_to_zero = current_speed / net_acceleration
  # pad the time to zero so we have an extra second at the end
  time_to_zero += 1.0
  distance_to_zero = current_speed * time_to_zero + 0.5 * (-net_acceleration) * (time_to_zero**2)
  puts "%.2f * %.2f + 0.5 * %.2f * (%.2f^2) = %.2f" % [
    current_speed, time_to_zero, -net_acceleration, time_to_zero, distance_to_zero
  ]
  return distance_to_zero
end

def desired_throttle(current_speed, desired_speed, vessel_mass, vessel_thrust, surface_gravity)
  desired_acceleration = current_speed - desired_speed
  total_acceleration = surface_gravity + desired_acceleration
  throttle = total_acceleration / (@vessel.available_thrust / @vessel.mass); p throttle; sleep(0.01)
  return throttle
end

Kerbal.run
