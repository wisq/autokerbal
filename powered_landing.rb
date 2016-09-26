#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

HORIZONTAL_ALTITUDE_MARGIN = 100 # height (m) above surface at which to do horizontal burn

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
  minimum_speed = 3.0
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

            if thrust == 0.0
              puts "No thrust available!"
              sleep(0.5)
              next
            end

            if state == :wait_horizontal_burn
              # This function is slow, but it collects all relevant data
              # at the start, so we offset it by how long it takes.
              start = @space_center.ut
              suicide_time = suicide_burn_time(@vessel, thrust, mass, HORIZONTAL_ALTITUDE_MARGIN)
              if suicide_time
                elapsed = @space_center.ut - start

                time_to_burn = suicide_time - elapsed
                puts "seconds to horizontal burn: #{time_to_burn}"

                dewarp if time_to_burn < 30
                if time_to_burn < 1
                  puts "transition to horizontal burn"
                  state = :horizontal_burn
                end
              else
                puts "no predicted impact yet"
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
                suicide_altitude = vertical_suicide_altitude(speed, minimum_speed, mass, thrust, gravity)
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

def vertical_suicide_altitude(current_speed, target_speed, vessel_mass, vessel_thrust, surface_gravity)
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

def suicide_burn_time(vessel, vessel_thrust, vessel_mass, altitude_margin)
  time_to_impact, velocity_at_impact = time_and_velocity_to_impact(vessel, altitude_margin)
  return nil if time_to_impact.nil?
  ship_acceleration = vessel_thrust / vessel_mass
  time_to_zero = velocity_at_impact / ship_acceleration
  return time_to_impact - time_to_zero
end

def time_and_velocity_to_impact(vessel, altitude_margin)
  body = vessel.orbit.body
  ref_frame = body.non_rotating_reference_frame
  position = Vector[*vessel.position(ref_frame)]
  velocity = Vector[*vessel.velocity(ref_frame)]
  grav_param = body.gravitational_parameter

  start_position = position.dup
  meridian = Vector[1, 0, 0] # 0 degrees longitude at the equator
  equator_normal = Vector[0, 1, 0]

  rotating_offset = body_rotating_frame_offset(body)
  rotation_speed = rad2deg(body.rotational_speed)

  1.upto(600) do |time|
    # Calculate new position and velocity:
    height = position.magnitude # from center of planet
    gravity = grav_param / height**2
    gravity_factor = height / gravity
    gravity_vector = Vector[*(0..2).map { |i| -position[i] / gravity_factor }]
    velocity += gravity_vector
    position += velocity

    # Calculate lat and long for position:
    latitude  = angle_between_vector_and_plane(position, equator_normal)
    longitude = angle_between(meridian, Vector[position[0], 0, position[2]])
    longitude += rotating_offset - (rotation_speed * time)
    # longitude can be 360 degrees off (or more); surface_height can handle it

    # Is new position underground?
    surface_height = Vector[*body.surface_position(latitude, longitude, ref_frame)].magnitude
    if height <= (surface_height + altitude_margin)
      #p [latitude, longitude]
      return [time, velocity.magnitude]
    end
  end

  # Unknown or no time to impact
  return nil
end

Kerbal.run
