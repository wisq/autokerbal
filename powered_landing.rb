#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

Kerbal.thread 'landing' do
  dewarp
  @space_center.save('prelanding')

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

  flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  gravity = @vessel.orbit.body.surface_gravity

  time_to_land = 10.0
  minimum_speed = 5.0
  state = :wait_horizontal_burn

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

            suicide_altitude = suicide_burn_altitude(speed, minimum_speed, mass, thrust, gravity)

            if state == :wait_horizontal_burn
              target_altitude = suicide_altitude*2 + minimum_altitude
              delta = altitude - target_altitude
              puts "delta to horizontal burn: #{delta}"

              dewarp if delta < 100
              if altitude <= target_altitude
                puts "transition to horizontal burn"
                state = :horizontal_burn
              end
            end

            if state == :horizontal_burn
              # target speed = 1.0
              @control.throttle = desired_throttle(speed, 1.0, mass, thrust, gravity)
              if speed <= 2.0
                puts "transition to suicide burn"
                state = :suicide_burn
              end
            end

            if state == :suicide_burn
              if speed <= minimum_speed
                if altitude <= minimum_altitude
                  puts "transition to final"
                  @autopilot.reference_frame = @vessel.surface_reference_frame
                  @autopilot.target_pitch = 90
                  @autopilot.engage
                  state = :final
                else
                  # wait for minimum altitude
                  @control.throttle = 0.0
                end
              else
                target_altitude = suicide_altitude + minimum_altitude
                delta = altitude - target_altitude

                dewarp if delta < 100
                throttle = if delta < 0 then 1.0 else 0.0 end
                puts "delta to suicide burn: #{delta}"
                @control.throttle = throttle
              end
            end

            if state == :final
              target_speed = altitude / time_to_land
              target_speed = minimum_speed if target_speed < minimum_speed
              @control.throttle = desired_throttle(speed, target_speed, mass, thrust, gravity)
              break if altitude < (minimum_speed / 2.0)
            end

            sleep(0.01)
          end

          @control.throttle = 0.0
          puts "We landed!  Huzzah!"
          puts "Press ctrl-C when ready to disengage autopilot."
          loop { sleep(10) }
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
  #puts "%.2f * %.2f + 0.5 * %.2f * (%.2f^2) = %.2f" % [
  #  current_speed, time_to_zero, -net_acceleration, time_to_zero, distance_to_zero
  #]
  return distance_to_zero
end

def desired_throttle(current_speed, desired_speed, vessel_mass, vessel_thrust, surface_gravity)
  desired_acceleration = current_speed - desired_speed
  total_acceleration = surface_gravity + desired_acceleration
  return total_acceleration / (@vessel.available_thrust / @vessel.mass)
end

Kerbal.run
