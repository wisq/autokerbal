#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

require 'ruby-mpd'

SLEEP_DURATION = {
  pre_launch: 0.1,
}
DEFAULT_SLEEP = 1

Kerbal.thread 'kmpc', with_vessel: false do
  monitor = SituationMonitor.new
  loop do
    vessel = nil
    begin
      vessel = @space_center.active_vessel
    rescue KRPC::RPCError => e
      raise unless e.message.include?('Procedure not available in game scene')
    end

    monitor.update(vessel)
    sleep(monitor.loop_sleep_duration)
  end
end

class SituationMonitor
  SPACE_SITUATIONS  = [:orbiting, :escaping, :sub_orbital]
  LANDED_SITUATIONS = [:landed, :splashed]

  def initialize
    @vessel = nil
    @meta_state = nil
    @mpc = MPC.new
  end

  def update(vessel)
    if vessel.nil?
      puts "No active vessel." if @vessel
    elsif @vessel.nil? || vessel.remote_oid != @vessel.remote_oid
      puts "Monitoring vessel: #{vessel.name}"
      @meta_state = nil
    end
    @vessel = vessel

    update_situation
  end

  def target_meta_state(situation)
    if situation == :escaping || situation == :orbiting
      return :space
    elsif situation == :sub_orbital
      # If we're in a launch, keep us there until we're orbital.
      if @meta_state == :launch
        return :launch
      else
        return :space
      end
    elsif situation == :flying
      # I figure, if we go from pre_launch to flying, it's a KSC rocket launch.
      # Otherwise, it's probably a reentry.
      #
      # I might need to revise this if I ever design rockets that launch
      # from the pad with no launch clamps.  pre_launch -> landed -> flying?
      if [:launch, :pre_launch].include?(@meta_state)
        return :launch
      else
        return :reentry
      end
    elsif situation == :landed || situation == :splashed
      # Landed on Kerbin/Earth = celebratory return home.
      # Landed anywhere else = still space.
      # I want to eventually maybe add a playlist for landed on planet w/ atmosphere.
      if %w(Earth Kerbin).include?(@vessel.orbit.body.name)
        # Work around bug where prelaunch ships show up as landed.
        return :pre_launch if has_launch_clamps?(@vessel)
        return :home
      else
        return :space
      end
    elsif situation == :pre_launch
      return :pre_launch
    elsif situation == :docked
      # Well, this shouldn't happen.  As soon as a vessel gets docked,
      # we should be controlling the whole docked assembly, so I'm
      # guessing this is a temporary state and vessel will change shortly.
      warn "Vessel situation is :docked"
      return nil
    else
      raise "Unknown situation: #{situation.inspect}"
    end
  end

  def has_launch_clamps?(vessel)
    return !vessel.parts.with_module('LaunchClamp').empty?
  end

  def update_situation
    if @vessel.nil?
      return update_meta_state(:ksc)
    end

    meta = target_meta_state(@vessel.situation)
    update_meta_state(meta) unless meta.nil?
  end

  DEFAULT_PARAMS = {
    mode: :fade,
    fade: 3.0,
  }
  SPECIAL_TRANSITIONS = {
    # When recovering a vessel, let the current song (probably celebratory) finish
    # before returning to normal space center music.
    [:home, :ksc] => {mode: :crop},
    # When launching, do a very fast transition.
    [nil, :launch] => {fade: 1.0},
  }

  LOOP_SLEEP = {
    :pre_launch => 0.1,
    :reentry => 0.5,
  }
  LOOP_SLEEP_DEFAULT = 1.0

  def loop_sleep_duration
    return LOOP_SLEEP.fetch(@meta_state, LOOP_SLEEP_DEFAULT)
  end

  def transition_params(old, new)
    params = DEFAULT_PARAMS
    [[old, nil], [nil, new], [old, new]].each do |key|
      params = params.merge(SPECIAL_TRANSITIONS.fetch(key, {}))
    end
    return params
  end

  def update_meta_state(new_state)
    params = transition_params(@meta_state, new_state)
    @mpc.change_playlist(new_state, **params)
    @meta_state = new_state
  end
end

class MPC
  def initialize
    @playlist_name = nil
    @mpd = mpd_from_env
  end

  def mpd_from_env
    host = ENV.fetch('MPD_HOST', 'localhost')
    port = ENV.fetch('MPD_PORT', '6600').to_i
    password, _, host = host.rpartition('@')
    password = nil if password.empty?

    mpd = MPD.new(host, port, password: password)
    mpd.connect
    return mpd
  end

  def change_playlist(to_playlist, mode:, fade:)
    return if @playlist == to_playlist
    @playlist = to_playlist

    playlist_name = "ksp_#{to_playlist}"

    status = lambda do |msg|
      $stdout.print("#{msg} ... ")
      $stdout.flush
    end
    $stdout.print "Changing playlist: "
    $stdout.flush

    playlist = @mpd.playlists.find { |pl| pl.name == playlist_name }
    if playlist.nil?
      $stdout.puts "playlist #{playlist_name.inspect} not found."
      return
    end

    if !playing?
      mode = :cut
    elsif playlist_contains_current_song?(playlist)
      mode = :crop
    end

    fade_duration = nil
    if !fade
      mode = :cut if mode == :fade
    else
      fade_duration = fade
    end

    if mode == :crop
      status.call "cropping"
      crop
    elsif mode == :fade
      status.call "fade out"
      fade_out(fade_duration)
    end

    status.call "load #{playlist.name.inspect}"
    @mpd.clear unless mode == :crop
    load_playlist(playlist)

    if @mpd.status[:playlistlength] == 0
      $stdout.puts "empty playlist."
      return
    elsif mode == :fade
      status.call "fade in"
      fade_in(fade_duration)
    elsif mode == :cut || !playing?
      play
    end

    $stdout.puts "done."
  end

  def load_playlist(playlist)
    playlist.load
    @mpd.shuffle
  end

  def playlist_contains_current_song?(playlist)
    return playlist.songs.any? { |s| s.file == @mpd.current_song.file }
  end

  def crop
    status = @mpd.status
    # Move current song to top.
    @mpd.move(status[:song], 0)
    # Clear remaining playlist.
    @mpd.delete(1..status[:playlistlength])
  end

  def fade_to(target_volume, duration)
    time_per_percent = duration / 100.0

    current_volume = start_volume = @mpd.volume
    return if current_volume == target_volume

    step = if target_volume < current_volume then -1 else 1 end
    min, max = [target_volume, current_volume].sort

    start = Time.now
    until current_volume == target_volume
      time_since_start = Time.now - start
      steps_complete = (time_since_start / time_per_percent).floor

      new_volume = start_volume + (step * steps_complete)

      if new_volume != current_volume
        new_volume = min if new_volume < min
        new_volume = max if new_volume > max
        @mpd.volume = current_volume = new_volume
      else
        # sleep until next step
        next_step = steps_complete + 1
        next_step_time = start + (time_per_percent * next_step)

        time_to_sleep = next_step_time - Time.now
        sleep(time_to_sleep) if time_to_sleep >= 0.0
      end
    end
  end

  def fade_out(duration)
    fade_to(0, duration)
  end

  def fade_in(duration)
    unless playing?
      @mpd.volume = 0
      @mpd.play
    end

    fade_to(100, duration)
  end

  def play
    @mpd.volume = 100
    @mpd.play
  end

  def playing?
    return @mpd.playing?
  end
end

Kerbal.run
