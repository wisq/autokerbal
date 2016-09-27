#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

MINIMUM_THRUST = 0.1  # minimum thrust factor (10%)
MINIMUM_DELTA  = 0.01 # speed delta below which to not thrust
MAXIMUM_ERROR = 0.2   # metres of lateral error

Kerbal.thread 'docking' do
  target = @space_center.target_docking_port
  raise "no target docking port" if target.nil?

  puts "Target: #{target.part.title} on #{target.part.vessel.name}"
  our_port = @vessel.parts.controlling.docking_port

  puts "Aligning with docking port ..."
  @control.sas = false
  @autopilot.reference_frame = target.reference_frame
  @autopilot.target_direction = [0, -1, 0]
  @autopilot.target_roll = 0
  @autopilot.engage
  sleep(1)
  @autopilot.wait

  @control.rcs = true
  closing_stage = false

  until target.state == :docking do
    position = Vector[*our_port.position(target.reference_frame)]
    velocity = Vector[*@vessel.velocity(target.reference_frame)]
    on_target = true

    # FIXME: man this is gross
    #
    #  * create a generic function to handle all directions
    #  * translate vessel velocity to docking port velocity
    #  * use correct up/right/forward based on translated velocity

    y_delta = position[0]
    y_speed = velocity[0]
    if y_delta.abs <= MAXIMUM_ERROR
      change_y_speed(0.0, y_speed)
    else
      on_target = false
      target_speed = -y_delta / 20.0
      target_speed =  1 if target_speed >  1
      target_speed = -1 if target_speed < -1
      change_y_speed(target_speed, y_speed)
    end

    x_delta = position[2]
    x_speed = velocity[2]
    if x_delta.abs <= MAXIMUM_ERROR
      change_x_speed(0.0, x_speed)
    else
      on_target = false
      target_speed = -x_delta / 20.0
      target_speed =  1 if target_speed >  1
      target_speed = -1 if target_speed < -1
      change_x_speed(target_speed, x_speed)
    end

    closing_stage = true if on_target

    z_delta = position[1]
    z_speed = velocity[1]
    if closing_stage
      target_speed = -z_delta / 20.0
      change_z_speed(target_speed, z_speed)
    else
      change_z_speed(0.0, z_speed)
    end

    p [x_delta, y_delta, z_delta, on_target]
    sleep(0.1)
  end

  @control.up = 0.0
  @control.right = 0.0
  @control.rcs = false

  puts "In range of docking port, waiting for docking."
  while target.state == :docking
    sleep(0.2)
  end

  @autopilot.disengage

  if target.state == :docked
    puts "Docking complete!"
  else
    puts "Docking failed!"
    @control.sas = true
  end
end

def change_y_speed(target_speed, current_speed)
  delta = (target_speed - current_speed) * 2
  if delta.positive?
    delta = MINIMUM_THRUST if delta < MINIMUM_THRUST && delta > MINIMUM_DELTA
  else
    delta = -MINIMUM_THRUST if delta > -MINIMUM_THRUST && delta > MINIMUM_DELTA
  end
  p ['change_y', target_speed, current_speed, delta]
  @control.up = delta
end

def change_x_speed(target_speed, current_speed)
  delta = (target_speed - current_speed) * 2
  if delta.positive?
    delta = MINIMUM_THRUST if delta < MINIMUM_THRUST && delta > MINIMUM_DELTA
  else
    delta = -MINIMUM_THRUST if delta > -MINIMUM_THRUST && delta > MINIMUM_DELTA
  end
  p ['change_x', target_speed, current_speed, delta]
  @control.right = -delta
end

def change_z_speed(target_speed, current_speed)
  p ['change_z', target_speed, current_speed]
  delta = (target_speed - current_speed) * 2
  if delta.positive?
    delta = MINIMUM_THRUST if delta < MINIMUM_THRUST && delta > MINIMUM_DELTA
  else
    delta = -MINIMUM_THRUST if delta > -MINIMUM_THRUST && delta > MINIMUM_DELTA
  end
  p ['change_z', target_speed, current_speed, delta]
  @control.forward = -delta
end

Kerbal.run
