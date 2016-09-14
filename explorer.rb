#!/usr/bin/env ruby

require 'bundler/setup'
require 'krpc'
require 'pry'

PROGRAM = File.basename($0, ".rb")
@client  = KRPC.connect(name: PROGRAM, host: "omgwtfhax.wisq.org")
@space_center = @client.space_center
@vessel  = @space_center.active_vessel
@control = @vessel.control
pry
