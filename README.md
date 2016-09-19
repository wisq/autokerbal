# autokerbal

A collection of Ruby scripts for automating various things in Kerbal, using the kRPC mod.

## Who is this for?

Well, primarily, it's for me!  But it may also be useful to anyone else who plays Kerbal, and (ideally) already knows how to write Ruby code.

**If you are not a programmer, I would not recommend using these scripts!**  You're better off just using something like MechJeb.  Honestly, they've put a lot more time and effort into their automation, and they've made it accessible for everyone.

So if MechJeb already exists, why am I making this?  Well, mainly for fun, and challenge, and because it lets me make complex decisions and automate things that MechJeb can't do.  Plus, there's a satisfaction to using my own code to Kerbal, and in constantly updating it to deal with failures and edge cases.

If that sounds fun to you, then maybe you'll find these useful.

## What's the plan here?  Where's this going?

I'm not sure where I'm going with this.  Will I stick with just automating a few tasks, like a self-made MechJeb?  Will I ever have (e.g.) 100% automated supply missions?  Will I eventually automate *everything*?  No idea!

That said, the scripts here are usable *right now*, and are being continuously improved as I discover edge cases, optimisations, etc.

## Using these scripts

### Prerequisites

* You'll need a working copy of Ruby.  There's plenty of ways to do that, but the one I use is https://github.com/rbenv/rbenv .
* You'll also need bundler.  If you've got a working Ruby, you should be able to just do `gem install bundler`.
* Finally, you'll need the [kRPC mod](https://krpc.github.io/krpc/) itself.
  * Follow the "Getting Started Guide" to install the mod.
  * I highly recommend enabling "auto-accept new clients".  My scripts connect one client per thread, and that can get messy and cumbersome if you have to approve each one.
  * Don't forget to start the server!  (I have "auto-start server" enabled.)

### Installation

Just run `bundle install` in this directory.  All the necessary Ruby gems will be downloaded and installed.

### Usage

Most of these scripts are standalone.  Just run them, e.g. `./burn.rb` to execute a burn.

Some scripts may expect command-line arguments.  E.g. `target.rb` expects the name of a planet or ship.

Some scripts reuse each other, e.g. (as of this writing) `launch.rb` uses `burn.rb` for the circularisation burn, `autostage.rb` for staging during launch, `descent.rb` for the automatic abort procedure, etc.

I'll try to document things more in the future, but right now, I'm just hacking away at them.  Read the scripts themselves to get an idea of what they do.

### Controlling KSP from a different computer

Personally, I run Kerbal on my desktop (geared for gaming), and control it from my laptop (geared for development).  If you want to do a similar setup, you'll need to do two things:

1. Set your IP address in the kRPC configuration (inside KSP) to the local network IP of your KSP computer.
2. Copy the `config.yml.example` file to `config.yml` and edit it to point to that same IP.
