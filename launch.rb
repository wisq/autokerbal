#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'set'

FLYING_STATES = Set.new [:flying, :orbiting, :escaping, :sub_orbital]

WAIT_ALLOW_INVERTED = true  # allow launching at descending node, if sooner

INCLINATION = 0  # will match target inclination if target selected
INITIAL_SPEED = 50  # speed to begin gravity turn
INITIAL_PITCH = {
  true  => 75,  # pitch for initial gravity turn if atmosphere present
  false => 30,  # pitch for initial gravity turn if in vacuum
}
ASCENT_AOA = 3  # angle of attack during ascent
ORBIT_ALTITUDE = 100000   # target orbit altitude

ABORT_ALTITUDE_MAX = 50000 # cut throttle if alt below this & decreasing
ABORT_ALTITUDE_MIN = 10000 # omg we're gonna crash

Kerbal.thread 'launch' do
  situation = @vessel.situation
  raise "Already launched: #{situation}" unless [:pre_launch, :landed].include?(situation)

  body_flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  svel_flight = @vessel.flight(@vessel.surface_velocity_reference_frame)
  surface_flight = @vessel.flight(@vessel.surface_reference_frame)

  dewarp
  @space_center.save('prelaunch')

  @vessel.parts.modules_with_name('ModuleResourceConverter').each do |mod|
    next unless mod.part.launch_clamp
    next unless mod.has_event('Start Pumping Fuel')
    puts "Enabling fuel pumping: #{mod.part.title}"
    mod.trigger_event('Start Pumping Fuel')
  end

  target_inclination = INCLINATION
  target = @space_center.target_body || @space_center.target_vessel
  # Orbit inclination is supposed to be returned as radians,
  # but the current version converts the wrong way (rad2deg).
  # A single deg2rad will give us the degrees inclination.
  # FIXME: Change this to rad2deg once the bug is fixed.
  target_inclination = deg2rad(target.orbit.inclination) if target

  if target && target_inclination >= 0.1
    target_longitude = rad2deg(target.orbit.longitude_of_ascending_node)

    puts "Target: #{target.name}"
    puts "Inclination: #{target_inclination}"
    puts "Longitude of ascending node: #{target_longitude}"
    puts
    puts "Waiting until vessel is under #{target_longitude} longitude."
    degrees_needed, time = time_to_longitude(target_longitude)

    puts
    puts "Degrees until longitude: #{degrees_needed}"
    puts "Time until longitude: #{time} seconds"
    puts "Launch inclination: #{target_inclination}"
    puts

    if degrees_needed > 180 && WAIT_ALLOW_INVERTED
      target_longitude = (target_longitude + 180) % 360
      puts "Will launch at descending node instead (#{target_longitude} degrees)."
      degrees_needed, time = time_to_longitude(target_longitude)

      target_inclination = -target_inclination

      puts
      puts "Degrees until longitude: #{degrees_needed}"
      puts "Time until longitude: #{time} seconds"
      puts "Launch inclination: #{target_inclination}"
      puts
    end

    time_ut = @space_center.ut + time

    5.downto(1) do |n|
      puts "Warping in #{n} ...\007"
      sleep(1)
    end

    @space_center.warp_to(time_ut - 11.0)
    dewarp
    sleep(1)

    degrees, time = time_to_longitude(target_longitude)
    countdown_ut = @space_center.ut + time - 5.0
    puts "Degrees until longitude: #{degrees_needed}"
    puts "Time until longitude: #{time} seconds"
    raise "ERROR: Warped too far!" if time < 6.0
    raise "ERROR: Not enough warp!" if time > 20.0

    puts "Beginning countdown in %.2f seconds." % [countdown_ut - @space_center.ut]
    sleep(0.1) until @space_center.ut >= countdown_ut
  end

  @control.sas = false
  @control.throttle = 0.0

  @autopilot.stopping_time = [0.5, 0.5, 0.5] # the default
  @autopilot.target_heading = inclination_to_heading(target_inclination)
  @autopilot.target_pitch = 90
  @autopilot.target_roll = 0
  @autopilot.engage

  5.downto(1) do |n|
    puts "Launching in #{n} ..."
    sleep(1)
  end
  puts "LAUNCH!"

  found_engine = false
  current_stage = @control.current_stage
  if @vessel.available_thrust == 0.0
    @vessel.parts.modules_with_name('ModuleEnginesFX').each do |mod|
      if mod.has_event('Activate Engine') && mod.part.stage == current_stage
        puts "Activating engine: #{mod.part.title}"
        mod.trigger_event('Activate Engine')
      end
    end
    @control.activate_next_stage unless found_engine
  end

  @control.throttle = 1.0

  Kerbal.start_thread('autostage')
  Kerbal.start_thread('launch_abort')
  Kerbal.start_thread('heat_limiter')
  Kerbal.start_thread('apoapsis')

  with_stream(body_flight.speed_stream) do |speed|
    until speed.get > INITIAL_SPEED
      sleep(0.05)
    end
  end

  initial_pitch = INITIAL_PITCH[@vessel.orbit.body.has_atmosphere]
  puts "Initial vertical ascent complete.  Tilting to #{initial_pitch} ..."
  @autopilot.target_pitch = initial_pitch

  last_latitude = nil
  with_streams(
    surface_flight.pitch_stream,
    surface_flight.latitude_stream,
    svel_flight.pitch_stream,
    @vessel.orbit.inclination_stream,
  ) do |
    surface_pitch_stream,
    latitude_stream,
    svel_pitch_stream,
    inclination_stream,
  |
    puts "Waiting for #{ASCENT_AOA} degrees AoA ..."
    waiting = true

    loop do
      current_pitch = surface_pitch_stream.get
      svel_pitch = current_pitch - svel_pitch_stream.get
      target_pitch = svel_pitch + ASCENT_AOA

      if waiting && target_pitch <= initial_pitch
        puts "Maintaining #{ASCENT_AOA} degrees AoA for ascent."
        puts "Waiting for #{ORBIT_ALTITUDE}m apoapsis ..."
        waiting = false
      end

      latitude = latitude_stream.get
      if last_latitude
        latitude_change = latitude - last_latitude
        # Inclination is supposed to be in radians,
        # but is actually in rad2deg(degrees).
        # A single deg2rad will solve this, but
        # this will eventually need to be rad2deg.
        inclination = deg2rad(inclination_stream.get)
        @autopilot.target_heading = target_heading = corrective_steering(
          target_inclination,
          inclination,
          latitude_change,
        )
        puts "Inclination: #{inclination}, lat #{latitude_change} ... corrective steering: #{target_heading}"
      end
      last_latitude = latitude

      unless waiting
        @autopilot.target_pitch = target_pitch
        @autopilot.engage
      end

      sleep_ut(0.1)
    end
  end
end

def inclination_to_heading(inc)
  # Although in real life, inclination is always positive,
  # we will use a negative inclination to indicate
  # that we should be turning south instead of north.
  return 90.0 - inc
end

def corrective_steering(target_inc, current_inc, latitude_change)
  # target_inc is positive if we should go north, negative if south.
  # current_inc always starts positive, so give it the "correct" sign.
  moving_north = latitude_change.positive?
  # positive if north, negative if south
  current_inc = -current_inc if !moving_north

  inclination_error = (target_inc - current_inc).abs
  base_heading = inclination_to_heading(target_inc)
  return base_heading if inclination_error < 0.05

  # Scale our turn up to 5 degrees if we are 1 degree off target_inc.
  degrees_turn_clockwise = [inclination_error * 5.0, 5.0].min # clockwise = south
  # Switch to north turn if target inclination is more northern.
  degrees_turn_clockwise = -degrees_turn_clockwise if target_inc > current_inc

  return base_heading + degrees_turn_clockwise
end

Kerbal.thread 'apoapsis', paused: true do
  with_stream(@vessel.orbit.apoapsis_altitude_stream) do |apoapsis|
    until apoapsis.get >= ORBIT_ALTITUDE
      sleep(0.1)
    end
    puts "Apoapsis achieved: #{apoapsis.get.to_i}m"
  end

  puts "Cutting throttle."
  @control.throttle = 0
  Kerbal.kill_thread('heat_limiter')

  body = @vessel.orbit.body
  atmosphere_depth = body.atmosphere_depth
  body_flight = @vessel.flight(body.reference_frame)

  puts "Waiting for exit from atmosphere ..."
  until body_flight.mean_altitude > atmosphere_depth
    sleep(1)
  end

  puts "Now in space!"
  Kerbal.kill_thread('launch')
  Kerbal.start_thread('in_vacuum')
  Kerbal.start_thread('circular')
end

Kerbal.thread 'circular', paused: true do
  body = @vessel.orbit.body
  atmosphere_depth = body.atmosphere_depth

  Kerbal.kill_thread('launch_abort')
  Kerbal.start_thread('reentry')

  puts "Plotting circularisation burn ..."
  plot_circular_node

  puts "ERROR: Burn failed!" unless Kerbal.run_thread('burn')

  puts
  puts "Periapsis: #{@vessel.orbit.periapsis_altitude.to_i}m"
  puts "Apoapsis:  #{@vessel.orbit.apoapsis_altitude.to_i}m"
  puts

  if @vessel.orbit.periapsis_altitude < atmosphere_depth
    puts "WARNING: Ship is still sub-orbital!"
    puts "Waiting for reentry."
  else
    puts "Ship has reached orbit."
    Kerbal.kill_thread('reentry')
  end

  Kerbal.kill_thread('autostage')
end

Kerbal.thread 'heat_limiter', paused: true do
  throttled = false

  loop do
    if @control.throttle > 0.0
      heat_ratios = @vessel.parts.all.map do |part|
        [part.temperature / part.max_temperature,
         part.skin_temperature / part.max_skin_temperature]
      end
      max_ratio = heat_ratios.flatten.max

      if max_ratio > 0.8
        # Keep heat in the range of 80% to 90%.
        reduction = 10 * (max_ratio - 0.8)
        throttle = 1.0 - reduction
        puts "Reducing throttle due to heat." unless throttled
        @control.throttle = [0, throttle].max
        throttled = true
      elsif throttled
        puts "Resuming max throttle."
        @control.throttle = 1.0
        throttled = false
      else
        @control.throttle = 1.0
        sleep(0.5)
      end
    end
  end
end

Kerbal.thread 'reentry', paused: true do
  body = @vessel.orbit.body
  atmosphere_depth = body.atmosphere_depth
  flight = @vessel.flight(body.reference_frame)
  old_in_space = nil

  until flight.mean_altitude > atmosphere_depth
    sleep(5)
  end

  puts "Now in space; watching for reentry."
  until flight.mean_altitude < atmosphere_depth
    sleep(1)
  end

  if Kerbal.thread_running?('launch')
    puts "Reentry detected.  Aborting launch."
  elsif Kerbal.thread_running?('circular')
    puts "Reentry detected.  Aborting circularisation."
  else
    puts "Reentry detected."
  end
  Kerbal.kill_other_threads
  Kerbal.start_thread('descent')
end

Kerbal.thread 'launch_abort', paused: true do
  flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  altitude_stream = flight.mean_altitude_stream

  last_altitude = altitude_stream.get
  decrease_times = 0
  loop do
    altitude = altitude_stream.get
    if altitude > last_altitude
      decrease_times = 0
    elsif altitude < last_altitude
      decrease_times += 1
      break if decrease_times >= 10 && altitude < ABORT_ALTITUDE_MAX
    end
    last_altitude = altitude
    sleep(0.2)
  end

  puts "Altitude decreasing!  Aborting launch!"
  Kerbal.kill_other_threads

  @control.throttle = 0
  emergency = false
  puts "Waiting for zero thrust ..."
  until @vessel.thrust == 0.0
    if altitude_stream.get < ABORT_ALTITUDE_MIN
      puts "Altitude too low!  Emergency abort!"
    end
    sleep(0.2)
  end

  Kerbal.start_thread('descent')
end

Kerbal.thread 'in_vacuum', paused: true do
  @vessel.parts.modules_with_name('ProceduralFairingDecoupler').each do |mod|
    if mod.has_event('Jettison')
      puts "Jettisoning fairing: #{mod.part.title}"
      mod.trigger_event('Jettison')
    end
  end
  sleep(5)

  action = 'Extend Panels'
  modules = @vessel.parts.all.map do |part|
    part.modules.select { |mod| mod.has_event(action) }
  end.flatten(1)

  modules.each do |mod|
    puts "Extending solar panels: #{mod.part.title}"
    mod.trigger_event(action)
  end
end

Kerbal.load_file('descent.rb')
Kerbal.load_file('burn.rb')
Kerbal.load_file('autostage.rb')

def plot_circular_node
  mu = @vessel.orbit.body.gravitational_parameter
  r  = @vessel.orbit.apoapsis
  a1 = @vessel.orbit.semi_major_axis
  a2 = r
  v1 = Math.sqrt(mu*((2.0/r)-(1.0/a1)))
  v2 = Math.sqrt(mu*((2.0/r)-(1.0/a2)))
  delta_v = v2 - v1
  node = @vessel.control.add_node(
    @space_center.ut + @vessel.orbit.time_to_apoapsis,
    prograde: delta_v)
  return node
end

# TODO: staging
def calculate_time_for_burn(delta_v)
  f   = @vessel.available_thrust
  isp = @vessel.specific_impulse * 9.82
  m0  = @vessel.mass

  m1 = m0 / Math.exp(delta_v/isp)
  flow_rate = f / isp
  burn_time = (m0 - m1) / flow_rate

  return burn_time
end

def time_to_longitude(target)
  body = @vessel.orbit.body
  flight = @vessel.flight(body.non_rotating_reference_frame)

  # Get the angle of the planet relative to its fixed, non-rotating plane.
  angle = body_rotating_frame_offset(body)

  # Add that to our current longitude to get our non-rotated longitude
  current = (angle + flight.longitude) % 360

  needed = target - current
  needed += 360 if needed < 0
  speed = rad2deg(body.rotational_speed)
  time = needed / speed
  return needed, time
end

Kerbal.run
