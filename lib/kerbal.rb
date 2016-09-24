require 'bundler/setup'
require 'krpc'
require 'pry'
require 'matrix'
require 'singleton'
require 'yaml'
require 'pathname'

PROGRAM = File.basename($0, ".rb")

def _symbolify_keys(hash)
  return hash.map do |key, value|
    if value.kind_of?(Hash)
      value = _symbolify_keys(value)
    end
    [key.to_sym, value]
  end.to_h
end

def _load_config
  base_path = Pathname(__FILE__).dirname.dirname
  config_files = [
    base_path + 'config.yml',
    base_path + 'config.default.yml',
  ]
  config = YAML.load_file(config_files.find(&:exist?).to_s)
  return _symbolify_keys(config)
end

CONFIG = _load_config
KRPC_CONFIG = CONFIG[:krpc]

class Kerbal
  include Singleton

  class ThreadKilled < Exception; end

  def initialize
    @definitions = {}
    @running = {}
    @start_queue = []
    @exit_status = {}
    @loading_file = false
  end

  def define(name, block)
    @definitions[name] = block
  end

  def start_or_queue(name)
    if @running[name]
      puts "Thread already running: #{name}"
      return
    elsif @start_queue
      # delay starting until main loop is run
      @start_queue << name unless @start_queue.include?(name)
      return
    else
      start_thread(name)
    end
  end

  def start_thread(name)
    block = @definitions[name]
    raise "Thread definition not found: #{name}" unless block

    puts "Starting thread: #{name}"
    @running[name] = Thread.new do
      begin
        retval = KerbalThread.new(name).run(block)
        @exit_status[name] = [:exit, retval]
        puts "Thread complete: #{name}"
      rescue ThreadKilled => e
        @exit_status[name] = [:killed, e]
      rescue Exception => e
        puts "Thread #{name.inspect} died with #{e.inspect}:"
        e.backtrace.each do |bt|
          puts "    #{bt}"
        end
        @exit_status[name] = [:exception, e]
      ensure
        @main_thread.wakeup
      end
    end
  end

  def self.thread(name, paused: false, &block)
    instance.define(name, block)
    start_thread(name) unless paused || instance.loading_file?
  end

  def self.execute(name, &block)
    KerbalThread.new(name).run(block)
  end

  def self.start_thread(name)
    instance.start_or_queue(name)
  end

  def self.run_thread(name)
    start_thread(name)
    until thread_running?(name)
      sleep(0.1)
    end
    while thread_running?(name)
      sleep(1)
    end
    return instance.thread_status(name) == :exit
  end

  def thread_status(name)
    return @exit_status[name][0]
  end

  def self.run
    instance.main_loop
  end

  def self.load_file(file)
    instance.load_file(file)
  end

  def loading_file?
    return @loading_file
  end

  def load_file(file)
    @loading_file = true
    load(file)
  ensure
    @loading_file = false
  end

  def main_loop
    return if loading_file?
    raise "Main loop already running" if @main_thread
    @main_thread = Thread.current

    while name = @start_queue.shift
      start_thread(name)
      sleep(0.1)
    end
    @start_queue = nil

    until @running.empty?
      sleep(0.1)
      @running.delete_if { |name, thread| !thread.alive? }
      sleep(1)
    end
  end

  def self.kill_thread(name)
    instance.kill_thread(name)
  end

  def self.kill_other_threads
    instance.kill_other_threads
  end

  def kill_thread(name)
    thread = @running[name]
    if thread
      puts "Killing thread: #{name}"
      thread.raise(ThreadKilled) if thread.alive?
    else
      puts "Can't kill thread, not running: #{name}"
    end
  end

  def kill_other_threads
    @running.each do |name, thread|
      next if thread == Thread.current
      puts "Killing thread: #{name}"
      thread.raise(ThreadKilled) if thread.alive?
    end
  end

  def self.thread_running?(name)
    return instance.running?(name)
  end

  def running?(name)
    return @running.has_key?(name)
  end

  class KerbalThread
    def initialize(name)
      @client_name = name
    end

    def run(block)
      @client = KRPC.connect(name: @client_name, **KRPC_CONFIG)
      begin
        @space_center = @client.space_center
        @vessel = @space_center.active_vessel
        @control = @vessel.control
        @autopilot = @vessel.auto_pilot
        instance_eval(&block)
      ensure
        @client.close if @client
      end
    end

    def with_streams(*streams)
      yield *streams
    ensure
      streams.each(&:remove)
    end
    alias :with_stream :with_streams

    def dewarp
      warp_mode = @space_center.warp_mode
      @space_center.physics_warp_factor = 0 if warp_mode == :physics
      @space_center.rails_warp_factor = 0 if warp_mode == :rails
    end

    def realchute(part)
      part.modules.select { |m| m.name == 'RealChuteModule' }.first
    end

    def parts_below(part)
      return part.children.map do |child|
        [child] + parts_below(child)
      end.flatten(1)
    end

    # TODO: staging
    def calculate_time_for_burn(delta_v)
      f   = @vessel.available_thrust
      return if f == 0.0
      isp = @vessel.specific_impulse * 9.82
      m0  = @vessel.mass

      m1 = m0 / Math.exp(delta_v/isp)
      flow_rate = f / isp
      burn_time = (m0 - m1) / flow_rate

      return burn_time
    end

    def autopilot_wait_until(cutoff_ut, max_error: 1.0, min_time: 2.0)
      with_stream(@autopilot.error_stream) do |error_stream|
        with_stream(@space_center.ut_stream) do |ut_stream|
          on_target_until = nil
          loop do
            error = error_stream.get
            ut = ut_stream.get

            dewarp if error <= (max_error * 2)
            if error <= max_error
              on_target_until ||= ut + min_time
              if ut >= on_target_until
                return true
              end
            else
              on_target_until = nil
            end

            if ut >= cutoff_ut
              return false
            end

            sleep(0.1)
          end
        end
      end
    end

    def sleep_ut(seconds)
      sleep(seconds.to_f / @space_center.warp_rate)
    end

    def deg2rad(deg)
      return deg * Math::PI / 180.0
    end

    def rad2deg(rad)
      return rad * 180 / Math::PI
    end

    def angle_between(v1, v2)
      angle = rad2deg(v1.angle_with(v2))
      angle = -angle if v2[2] < v1[2]
      return angle
    end

    def angle_between_vector_and_plane(vector, normal)
      dp = vector.dot(normal)
      return 0 if dp == 0
      vm = vector.magnitude
      nm = normal.magnitude
      return Math.asin(dp / (vm*nm)) * (180.0 / Math::PI)
    end

    def body_rotating_frame_offset(body) # (right now)
      offset = Vector[*@space_center.transform_position(
        [1, 0, 0], body.reference_frame, body.non_rotating_reference_frame)]
      meridian = Vector[1, 0, 0]
      return angle_between(meridian, offset)
    end
  end
end
