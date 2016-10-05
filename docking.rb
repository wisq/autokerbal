#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

MINIMUM_THRUST = 0.1  # minimum thrust factor (10%)
MINIMUM_DELTA  = 0.01 # speed delta below which to not thrust
MAXIMUM_ERROR = 0.2   # metres of lateral error

Kerbal.thread 'docking' do
  target = @space_center.target_docking_port
  raise "no target docking port" if target.nil?
  our_port = @vessel.parts.controlling.docking_port
  raise "no controlling docking port" if our_port.nil?

  target_vessel = target.part.vessel
  puts "Target: #{target.part.title} on #{target_vessel.name}"
  puts "Controlling from: #{our_port.part.title}"

  puts "Aligning with docking port ..."
  # For some reason, I can't align directly to the target reference frame.
  # So I'll align to the ship instead.
  alignment = @space_center.transform_direction(
    direction: [0, -1, 0],
    from: target.reference_frame,
    to: target_vessel.reference_frame,
  )

  @control.sas = false
  @autopilot.reference_frame = target_vessel.reference_frame
  @autopilot.target_direction = alignment
  @autopilot.target_roll = 0
  @autopilot.engage
  sleep(1)
  @autopilot.wait

  closing_stage = false

  until target.state == :docking do
    @control.rcs = true
    position = Vector[*target.position(our_port.reference_frame)]
    velocity = Vector[*target_vessel.velocity(our_port.reference_frame)]
    on_target = true

    # FIXME: man this is gross
    #
    #  * create a generic function to handle all directions
    #  * translate vessel velocity to docking port velocity
    #  * use correct up/right/forward based on translated velocity

    x_delta = position[0]
    x_speed = -velocity[0]
    if x_delta.abs <= MAXIMUM_ERROR
      change_x_speed(0.0, x_speed)
    else
      on_target = false
      target_speed = x_delta / 5.0
      target_speed =  1 if target_speed >  1
      target_speed = -1 if target_speed < -1
      change_x_speed(target_speed, x_speed)
    end

    y_delta = position[2]
    y_speed = -velocity[2]
    if y_delta.abs <= MAXIMUM_ERROR
      change_y_speed(0.0, y_speed)
    else
      on_target = false
      target_speed = y_delta / 5.0
      target_speed =  1 if target_speed >  1
      target_speed = -1 if target_speed < -1
      change_y_speed(target_speed, y_speed)
    end

    closing_stage = true if on_target

    closing_delta = position[1]
    closing_speed = -velocity[1]

    unless closing_stage
      # Target a point 50m from their docking port
      closing_delta -= 50
    end

    target_speed = closing_delta / 10.0
    target_speed =  1 if target_speed >  1
    target_speed = -1 if target_speed < -1

    if closing_stage
      # always push closer
      target_speed = 0.1 if target_speed < 0.1
    end
    change_closing_speed(target_speed, closing_speed)

    p [x_delta, y_delta, closing_delta, on_target]
    sleep(0.1)
  end

  @control.up = 0.0
  @control.right = 0.0
  @control.forward = 0.0
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
  @control.up = -delta
end

def change_x_speed(target_speed, current_speed)
  delta = (target_speed - current_speed) * 2
  if delta.positive?
    delta = MINIMUM_THRUST if delta < MINIMUM_THRUST && delta > MINIMUM_DELTA
  else
    delta = -MINIMUM_THRUST if delta > -MINIMUM_THRUST && delta > MINIMUM_DELTA
  end
  p ['change_x', target_speed, current_speed, delta]
  @control.right = delta
end

def change_closing_speed(target_speed, current_speed)
  delta = (target_speed - current_speed) * 2
  if delta.positive?
    delta = MINIMUM_THRUST if delta < MINIMUM_THRUST && delta > MINIMUM_DELTA
  else
    delta = -MINIMUM_THRUST if delta > -MINIMUM_THRUST && delta > MINIMUM_DELTA
  end
  p ['change_z', target_speed, current_speed, delta]
  @control.forward = delta
end

Kerbal.run
