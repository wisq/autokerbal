#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'set'

FLYING_STATES = Set.new [:flying, :orbiting, :escaping, :sub_orbital]

HEADING = 90  # degrees on compass
INITIAL_SPEED = 50  # speed to begin gravity turn
INITIAL_PITCH = 70  # pitch for initial gravity turn
ASCENT_AOA = 3  # angle of attack during ascent
ORBIT_ALTITUDE = 100000   # target orbit altitude

ABORT_ALTITUDE_MAX = 50000 # cut throttle if alt below this & decreasing
ABORT_ALTITUDE_MIN = 10000 # omg we're gonna crash

Kerbal.thread 'autostage', paused: true do
  loop do
    if @control.current_stage <= 1
      break
    elsif FLYING_STATES.include?(@vessel.situation) \
        && @control.throttle > 0.0 \
        && @vessel.available_thrust == 0
      @control.activate_next_stage
      sleep(0.5)
    else
      sleep(0.2)
    end
  end
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
        throttle = 1.0 - 10 * (0.9 - max_ratio)
        puts "Reducing throttle due to heat."
        @control.throttle = [0, throttle].max
        throttled = true
      elsif throttled
        puts "Resuming max throttle."
        @control.throttle = 1.0
        throttled = false
      end
    end

    sleep(0.3)
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

Kerbal.thread 'launch' do
  situation = @vessel.situation
  raise "Already launched: #{situation}" unless situation == :pre_launch

  body_flight = @vessel.flight(@vessel.orbit.body.reference_frame)
  svel_flight = @vessel.flight(@vessel.surface_velocity_reference_frame)
  surface_flight = @vessel.flight(@vessel.surface_reference_frame)

  @control.sas = false
  @control.throttle = 1.0

  @autopilot.target_heading = HEADING
  @autopilot.target_pitch = 90
  @autopilot.target_roll = 0
  @autopilot.engage

  5.downto(1) do |n|
    puts "Launching in #{n} ..."
    sleep(1)
  end
  puts "LAUNCH!"
  @control.activate_next_stage

  Kerbal.start_thread('autostage')
  Kerbal.start_thread('launch_abort')
  Kerbal.start_thread('heat_limiter')
  Kerbal.start_thread('apoapsis')

  with_stream(body_flight.speed_stream) do |speed|
    until speed.get > INITIAL_SPEED
      sleep(0.05)
    end
  end

  puts "Initial vertical ascent complete.  Tilting to #{INITIAL_PITCH} ..."
  @autopilot.target_pitch = INITIAL_PITCH
  @autopilot.engage

  with_stream(surface_flight.pitch_stream) do |pitch|
    wait_for = 90 - (90-INITIAL_PITCH)/2 # halfway to correct pitch
    until pitch.get < wait_for
      sleep(0.1)
    end
    puts "Tilt in progress; pitch at #{wait_for} degrees."
  end

  with_stream(svel_flight.pitch_stream) do |pitch|
    puts "Waiting for #{ASCENT_AOA} degrees AoA ..."
    until pitch.get >= ASCENT_AOA
      sleep(0.1)
    end
  end

  puts "Maintaining #{ASCENT_AOA} degrees AoA for ascent."
  puts "Waiting for #{ORBIT_ALTITUDE}m apoapsis ..."

  loop do
    @autopilot.reference_frame = @vessel.surface_velocity_reference_frame
    @autopilot.target_direction = [0,1,0] # prograde
    @autopilot.target_pitch = ASCENT_AOA
    @autopilot.engage
    sleep(1)
  end
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

  Kerbal.kill_thread('launch')
  Kerbal.kill_thread('heat_limiter')
  Kerbal.start_thread('circular')
end

Kerbal.thread 'circular', paused: true do
  body = @vessel.orbit.body
  surface_height = body.equatorial_radius
  atmosphere_depth = body.atmosphere_depth

  body_flight = @vessel.flight(body.reference_frame)
  puts "Waiting for exit from atmosphere ..."
  until body_flight.mean_altitude > atmosphere_depth
    sleep(1)
  end

  puts "Now in space!"
  Kerbal.kill_thread('launch_abort')
  Kerbal.start_thread('reentry')

  puts "Plotting circularisation burn ..."
  plot_circular_node

  puts "ERROR: Burn failed!" unless Kerbal.run_thread('burn')

  puts
  puts "Periapsis: #{(@vessel.orbit.periapsis - surface_height).to_i}m"
  puts "Apoapsis:  #{(@vessel.orbit.apoapsis - surface_height).to_i}m"
  puts

  if @vessel.orbit.periapsis < (atmosphere_depth + surface_height)
    puts "WARNING: Ship is still sub-orbital!"
    puts "Waiting for reentry."
  else
    puts "Ship has reached orbit."
    Kerbal.kill_thread('reentry')
  end

  Kerbal.kill_thread('autostage')
end

Kerbal.load_file('descent.rb')
Kerbal.load_file('burn.rb')

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

Kerbal.run
