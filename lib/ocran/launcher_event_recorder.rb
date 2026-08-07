# frozen_string_literal: true

module Ocran
  # Records launcher-directed build events (environment exports and the
  # application exec command) while forwarding them to another launcher
  # builder. The recorded events can later be replayed into a further
  # builder — e.g. to produce a wrapper stub executable alongside the
  # launcher batch file in Inno Setup builds.
  class LauncherEventRecorder
    def initialize(launcher)
      @launcher = launcher
      @events = []
    end

    def export(name, value)
      @events << [:export, name, value]
      @launcher.export(name, value)
    end

    def exec(image, script, *argv)
      @events << [:exec, image, script, *argv]
      @launcher.exec(image, script, *argv)
    end

    def replay(builder)
      @events.each { |event, *args| builder.public_send(event, *args) }
    end
  end
end
