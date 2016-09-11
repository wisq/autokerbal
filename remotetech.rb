#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'matrix'

Kerbal.thread 'remotetech' do
  comms = @client.remote_tech.comms(@vessel)

  last_best_connected = nil
  target_list = []
  loop do
    if last_best_connected = check_connected(comms, last_best_connected)
      sleep(10)
      next
    else
      puts "No connection!  Trying to reestablish ..."
    end

    target_list = make_target_list if target_list.empty?
    next_target = target_list.shift

    if next_target == :best_omni
      try_best_omni
    else
      p next_target
      try_best_dish(*next_target)
    end

    sleep(1)
  end
end

def make_target_list
  kerbin = @space_center.bodies['Kerbin']
  vessels_by_body = {kerbin => []}

  rt = @client.remote_tech
  @space_center.vessels.each do |vessel|
    comms = rt.comms(vessel)
    next unless comms.has_connection

    (vessels_by_body[vessel.orbit.body] ||= []) << vessel
  end

  bodies = vessels_by_body.keys.sort_by do |body|
    Vector[*body.position(@vessel.reference_frame)].magnitude
  end

  targets = [:best_omni]
  bodies.each do |body|
    targets << [:body, body]
    vessels_by_body[body].each do |vessel|
      targets << [:vessel, vessel]
    end
  end
  targets << :additional_omni

  return targets
end

def check_connected(comms, last_best_connected)
  best_connected = best_antenna_module(status: 'Connected')
  if best_connected && best_connected != last_best_connected
    part = best_connected.part
    title = unique_part_title(part)
    if is_omni?(best_connected)
      puts "Connected via #{title}."
    else
      target = target_name(@client.remote_tech.antenna(part))
      puts "Connected to #{target} via #{title}."
    end
  end
  return best_connected
end

def try_best_omni(additional: false)
  best_active = best_antenna_module(omni: true, status: 'Operational')
  best_active_range = 0
  best_active_range = module_range(best_active) if best_active

  want_status = 'Off' if additional
  best_omni = best_antenna_module(omni: true, status: want_status)
  if best_omni.nil?
    if additional
      puts "No extra omnis available."
    else
      puts "No omnis available."
    end
    return
  end

  title = unique_part_title(best_omni.part)

  if !additional
    if is_active?(best_omni)
      puts "Best omni is already active: #{title}"
      return try_best_omni(additional: true)
    elsif best_active_range && module_range(best_omni) <= best_active_range
      # Shouldn't happen, due to sorting by active first.
      puts "Best omni does not offer any additional range: #{title}"
      return
    end
  end

  description = "best"
  description = "extra" if additional
  puts "Activating #{description} omni: #{title}"
  best_omni.trigger_event('Activate')
end

def try_best_dish(t_type, t_entity)
  best_dish = best_antenna_module(omni: false)
  raise "No dishes available" if best_dish.nil?

  title = unique_part_title(best_dish.part)
  antenna = @client.remote_tech.antenna(best_dish.part)

  if !is_active?(best_dish)
    puts "Activating best dish: #{title}"
    best_dish.trigger_event('Activate')
    sleep(5)
  end

  antenna.send(:"target_#{t_type}=", t_entity)
  puts "Pointed #{title} at #{target_name(antenna)}."
end

def is_active?(mod)
  return mod.fields['Status'] != 'Off'
end

STATUS_PREFERENCES = [
  'Connected',
  'Operational',
  'Off',
]

def best_antenna_module(status: nil, omni: nil)
  modules = @vessel.parts.modules_with_name('ModuleRTAntenna')
  modules = modules.select { |mod| mod.fields['Status'] == status } if status
  modules = modules.select { |mod| is_omni?(mod) == omni } if omni

  return modules.sort_by do |mod|
    range = module_range(mod)
    mod_stat = mod.fields['Status']
    pref = STATUS_PREFERENCES.index(mod_stat) or raise "Unknown status: #{mod_stat}"
    [-range, pref, mod.remote_oid]
  end.first
end

def is_omni?(mod)
  mod.has_field('Omni range')
end

RANGE_MULTIPLIERS = {
  'G' => 1_000_000_000,
  'M' => 1_000_000,
  'k' => 1_000,
  ''  => 1,
}

def parse_range(range)
  if range =~ /^(\d+\.\d+)([GMk]?)m$/
    base = $1.to_f
    multiplier = RANGE_MULTIPLIERS[$2]
    return base * multiplier if multiplier
  end

  raise "Unexpected range: #{range.inspect}"
end

KNOWN_RANGES = {
  'longAntenna' => parse_range('2.50Mm'),
  'RTShortAntenna1' => parse_range('500.00km'),
  'mediumDishAntenna' => parse_range('50.00Mm'),
}

def module_range(mod)
  raw_range = mod.fields['Omni range'] || mod.fields['Dish range']
  range = parse_range(raw_range)

  name = mod.part.name
  known = KNOWN_RANGES[name]

  if known
    if range > 0 && range != known
      puts "Mismatch for #{name}: expected range #{known}, got #{range}"
      return range
    end
    return known
  else
    puts "Unknown antenna type: #{name}"
    if range > 0
      puts "Please add this antenna to KNOWN_RANGES:"
      puts "  '#{name}' => parse_range('#{raw_range}'),"
      return range
    else
      return 0
    end
  end
end

def target_name(antenna)
  target = antenna.target
  if target == :none
    return "(none)"
  elsif target == :active_vessel
    return "(active vessel)"
  elsif target == :vessel
    return antenna.target_vessel.name
  elsif target == :celestial_body
    return antenna.target_body.name
  elsif target == :ground_station
    return antenna.target_ground_station
  else
    raise "Unexpected antenna target: #{target.inspect}"
  end
end

def unique_part_title(part)
  title = part.title
  all = part.vessel.parts.with_title(title)
  if all.count == 1
    return part.title
  else
    index = all.sort_by(&:remote_oid).index(part)
    return "#{part.title} (##{index + 1})"
  end
end

Kerbal.run
