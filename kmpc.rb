#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'

require 'ruby-mpd'

SLEEP_DURATION = {
  pre_launch: 0.1,
}
DEFAULT_SLEEP = 1

Kerbal.thread 'kmpc', with_vessel: false do
  mpc = MPC.new
  old_sit = old_vessel = nil
  loop do
    begin
      vessel = @space_center.active_vessel

      if old_vessel.nil? || vessel.remote_oid != old_vessel.remote_oid
        puts "Monitoring vessel: #{vessel.name}"
        old_sit = nil
      end
      old_vessel = vessel

      new_sit = @space_center.active_vessel.situation

      if old_sit != new_sit
        situation_change(mpc, old_sit, new_sit)
      end

      old_sit = new_sit
      sleep(SLEEP_DURATION.fetch(new_sit, DEFAULT_SLEEP))
    rescue KRPC::RPCError => e
      raise unless e.message.include?('Procedure not available in game scene')

      situation_change(mpc, old_sit, nil)
      old_sit = nil
    end
  end
end

SPACE_SITUATIONS  = [:orbiting, :escaping, :sub_orbital]
LANDED_SITUATIONS = [:landed, :splashed]

def situation_change(mpc, old_sit, new_sit)
  if new_sit.nil?
    return mpc.change_playlist(:space_center)
  elsif new_sit == :pre_launch
    return mpc.change_playlist(:pre_launch)
  elsif new_sit == :flying
    if old_sit.nil?
      # switched to flying ship, assume reentry
      return mpc.change_playlist(:reentry)
    elsif old_sit == :pre_launch
      return mpc.change_playlist(:launch) # launch in atmosphere
    elsif SPACE_SITUATIONS.include?(old_sit)
      return mpc.change_playlist(:reentry)
    end
  elsif SPACE_SITUATIONS.include?(new_sit)
    return mpc.change_playlist(:space)
  elsif LANDED_SITUATIONS.include?(new_sit)
    return mpc.change_playlist(:landed)
  end

  puts "Unknown situation change: #{old_sit.inspect} to #{new_sit.inspect}."
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

  def change_playlist(to_playlist)
    return if @playlist == to_playlist
    @playlist = to_playlist

    playlist_name = "ksp_#{to_playlist}"

    status = lambda do |msg|
      $stdout.print(msg)
      $stdout.flush
    end
    status.call "Changing playlist: "

    playlist = @mpd.playlists.find { |pl| pl.name == playlist_name }
    if playlist.nil?
      $stdout.puts "playlist #{playlist_name.inspect} not found."
      return
    end

    if playing?
      status.call "fade out ... "
      fade_out
      status.call "load #{playlist.name.inspect} ... "
      replace_playlist(playlist)
      status.call "fade in ... "
      fade_in
      $stdout.puts "done."
    else
      status.call "load #{playlist.name.inspect} ... "
      replace_playlist(playlist)
      status.call "play ..."
      play
    end

    $stdout.puts " done."
  end

  def replace_playlist(playlist)
    @mpd.clear
    playlist.load
    @mpd.shuffle
  end

  FADE_DURATION = 3.0 # seconds
  TIME_PER_FADE_PERCENT = FADE_DURATION / 100.0

  def fade_to(target_volume)
    current_volume = start_volume = @mpd.volume
    return if current_volume == target_volume

    step = if target_volume < current_volume then -1 else 1 end
    min, max = [target_volume, current_volume].sort

    start = Time.now
    until current_volume == target_volume
      time_since_start = Time.now - start
      steps_complete = (time_since_start / TIME_PER_FADE_PERCENT).floor

      new_volume = start_volume + (step * steps_complete)

      if new_volume != current_volume
        new_volume = min if new_volume < min
        new_volume = max if new_volume > max
        @mpd.volume = current_volume = new_volume
      else
        # sleep until next step
        next_step = steps_complete + 1
        next_step_time = start + (TIME_PER_FADE_PERCENT * next_step)

        time_to_sleep = next_step_time - Time.now
        sleep(time_to_sleep) if time_to_sleep >= 0.0
      end
    end
  end

  def fade_out
    fade_to(0)
  end

  def fade_in
    unless playing?
      @mpd.volume = 0
      @mpd.play
    end

    fade_to(100)
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
