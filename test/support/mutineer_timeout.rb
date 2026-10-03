# frozen_string_literal: true

# Loaded by Mutineer through .mutineer.yml `require:`, never by the test suite.
#
# Mutineer gives each mutant a hard-coded 10 seconds (Isolation::DEFAULT_TIMEOUT)
# and has no flag or config key to change it. A killed mutant stops at its first
# failing test, but a surviving one runs its whole covering set, and for the
# gate's code that set (gate, sweep, revision, check and report tests, each
# building git repositories) takes longer than 10 seconds. So the cap turned
# survivors into timeouts, which count as no verdict and hide them. 120 seconds
# leaves room for the slowest covering set under parallel load.
#
# Worth upstreaming to davidteren/mutineer as a --timeout flag and `timeout:`
# config key; then this file goes away.
if defined?(Mutineer::Isolation)
  Mutineer::Isolation.send(:remove_const, :DEFAULT_TIMEOUT)
  Mutineer::Isolation.const_set(:DEFAULT_TIMEOUT, 120)
end
