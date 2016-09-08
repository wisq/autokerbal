#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

BURN_GRACE = 5  # come out of warp 5 seconds before burn
BURN_EMERGENCY_GRACE = 10  # prompt for emergency burn at this point

Kerbal.thread 'burn' do
  puts "Finding node ..."
  burn_node = @control.nodes.first
  raise "No nodes" unless burn_node

  burn_time = calculate_time_for_burn(burn_node.remaining_delta_v)
  raise "No engines available" if burn_time.nil?
  burn_ut = burn_node.ut - (burn_time / 2.0)

  time_to_burn = burn_ut - @space_center.ut
  puts "Burn scheduled in #{time_to_burn} seconds."

  puts "Turning to burn direction ..."
  @autopilot.reference_frame = burn_node.reference_frame
  vector = burn_node.remaining_burn_vector(burn_node.reference_frame)
  @autopilot.target_direction = vector
  @autopilot.engage
  sleep(0.5)
  success = autopilot_wait_until(burn_ut - BURN_EMERGENCY_GRACE)
  dewarp

  emergency_burn = false
  if success
    time_to_burn = burn_ut - @space_center.ut
    puts "Burn now in #{time_to_burn} seconds."
    if time_to_burn > 10
      puts "Warping ..."
      @space_center.warp_to(burn_ut - BURN_GRACE)
    end

    with_stream(@space_center.ut_stream) do |ut|
      until ut.get >= burn_ut
        sleep(0.05)
      end
    end

    puts "Initiating burn ..."
  else
    puts "Unable to turn to burn direction in time!"
    5.downto(1) do |n|
      puts "Emergency burn in #{n} ..."
      sleep(1)
    end
    puts "Initiating emergency burn!"
    emergency_burn = true
  end

  fine_tuning = false
  loop do
    vector = burn_node.remaining_burn_vector(burn_node.reference_frame)
    burn_complete = vector[1] <= 0
    break if burn_complete

    # Reorient the autopilot
    @autopilot.target_direction = vector

    delta_v = burn_node.remaining_delta_v
    break if delta_v < 0.1
    throttle = 1.0

    remaining_burn = calculate_time_for_burn(delta_v)
    if remaining_burn < 1.0
      puts "Fine-tuning burn ..." unless fine_tuning
      fine_tuning = true
      throttle /= (1.1 / remaining_burn)
    end

    ap_error = @autopilot.error
    if ap_error > 1.0
      throttle /= @autopilot.error unless emergency_burn
    elsif emergency_burn
      puts "Emergency burn is now on target, whew."
      emergency_burn = false
    end
    @control.throttle = throttle

    sleep([remaining_burn * 0.2, 0.5].min)
  end

  @control.throttle = 0.0
  @autopilot.disengage
  puts "Burn complete!"
end

Kerbal.run
