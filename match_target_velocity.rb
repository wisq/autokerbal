#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'pp'

Kerbal.thread 'match_velocity' do
  dewarp
  @space_center.save('prematch_velocity')

  target = @space_center.target_vessel
  raise "No target" if target.nil?

  closest = closest_approaches(@vessel, target)
  now = @space_center.ut

  puts "Closest approaches:"
  closest.sort_by(&:last).each do |distance, time|
    puts "  #{distance.to_i}m in #{(time - now).to_i} seconds"
  end

  closest_distance, closest_time = closest.first
  speed1 = @vessel.orbit.orbital_speed_at(closest_time - now)
  speed2 =  target.orbit.orbital_speed_at(closest_time - now)
  rel_speed = (speed2 - speed1).abs
  puts "Relative orbital speed at closest approach: #{rel_speed.to_i} m/s"

  burn_time = calculate_time_for_burn(rel_speed)
  puts("Burn time: %.2f seconds" % burn_time)

  time_of_burn = closest_time - (burn_time / 2.0)

  if time_of_burn - now > 180.0
    5.downto(1) do |n|
      puts "Warping in #{n} ...\007"
      sleep(1)
    end
    puts "Warping ..."
    @space_center.warp_to(time_of_burn - 120)
  end

  # Recalculate time of burn based on more accurate velocity figures
  ref_frame = @vessel.orbit.body.non_rotating_reference_frame
  rel_speed = (Vector[*target.velocity(ref_frame)] - Vector[*@vessel.velocity(ref_frame)]).magnitude
  burn_time = calculate_time_for_burn(rel_speed)
  time_of_burn = closest_time - (burn_time / 2.0)

  puts("Burn time is now %.2f seconds." % burn_time)
  puts "Burning in #{time_of_burn - @space_center.ut} seconds."

  burning = false
  loop do
    rel_velocity = Vector[*target.velocity(ref_frame)] - Vector[*@vessel.velocity(ref_frame)]
    break if rel_velocity.magnitude < 1.0

    @autopilot.reference_frame = ref_frame
    @autopilot.target_direction = rel_velocity.to_a
    @autopilot.engage

    if !burning && @space_center.ut > time_of_burn
      puts "Initiating burn."
      burning = true
    end

    if burning && @autopilot.error.abs < 5
      @control.throttle = desired_throttle(rel_velocity.magnitude, 0.0)
    else
      @control.throttle = 0.0
    end

    sleep(0.01)
  end

  @control.throttle = 0
end

def closest_approaches(vessel1, vessel2)
  period = vessel1.orbit.period
  times_to_check = (1..30).map { |tenth| period/10.0 * tenth }.sort

  orbit1 = vessel1.orbit
  orbit2 = vessel2.orbit

  now = @space_center.ut
  cutoff = now + (period * 3)

  # 20 divisions per orbit
  # find 3 lowest
  return closest_approaches_between_ut(orbit1, orbit2, now, cutoff, divisions: 60, count: 3)
end

MIN_STEP = 1.0
MIN_FINAL_STEP = 0.1

def closest_approaches_between_ut(orbit1, orbit2, min_time, max_time, divisions: 10, count: 1)
  total_time = max_time - min_time
  step = total_time / divisions
  step = MIN_STEP if step < MIN_STEP

  check_times = min_time.step(by: step, to: max_time).to_a
  check_times << max_time if (max_time - check_times.last) > MIN_FINAL_STEP

  distance_time_pairs = check_times.map { |t| [relative_distance_at_time(orbit1, orbit2, t), t] }

  # Find the indices of the points where distances reach their lowest
  # before increasing again.
  troughs = []

  current_trough = nil
  last_distance = nil
  distance_time_pairs.each.with_index do |dtpair, index|
    distance, time = dtpair
    if last_distance.nil?
      # skip this iteration
    elsif distance < last_distance
      # we're decreasing, so prepare a trough record
      current_trough = [distance, time, index]
    else
      # we're increasing
      troughs << current_trough if current_trough
      current_trough = nil
    end
    last_distance = distance
  end

  if troughs.empty?
    min_distance, min_time = distance_time_pairs[0]
    max_distance, max_time = distance_time_pairs[-1]
    # must return array of arrays,
    # as if we only found one trough
    return [[
      [min_distance, min_time],
      [max_distance, max_time],
    ].min]
  end

  lowest_troughs = troughs.sort

  found = []
  count.times do
    trough_distance, trough_time, trough_index = lowest_troughs.shift
    break if trough_distance.nil?

    # now we want to find our neighbours
    min_index = [trough_index - 1, 0].max
    max_index = [trough_index + 1, distance_time_pairs.length - 1].min

    min_distance, min_time = distance_time_pairs[min_index]
    max_distance, max_time = distance_time_pairs[max_index]

    if step <= MIN_STEP
      # we stop here, so just return the lowest distance and time
      found << [
        [min_distance, min_time],
        [max_distance, max_time],
        [trough_distance, trough_time],
      ].min
    else
      # keep searching deeper
      found << closest_approaches_between_ut(orbit1, orbit2, min_time, max_time).first
    end
  end

  return found.sort
end

def relative_distance_at_time(orbit1, orbit2, time_ut)
  vector1 = Vector[*relative_orbit_position_at_time(orbit1, time_ut)]
  vector2 = Vector[*relative_orbit_position_at_time(orbit2, time_ut)]
  distance = (vector1 - vector2).magnitude
  return distance
end

def desired_throttle(current_speed, desired_speed)
  total_acceleration = current_speed - desired_speed
  return total_acceleration / (@vessel.available_thrust / @vessel.mass)
end

Kerbal.run
