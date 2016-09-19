#!/usr/bin/env ruby

$LOAD_PATH << File.join(File.dirname($0), 'lib')
require 'kerbal'
require 'matrix' # for Vector

Kerbal.execute 'explorer' do
  binding.pry
end
