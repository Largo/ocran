require 'fox16'
require 'logger'
include Fox
exit if defined?(Ocran)
logger = Logger.new(STDOUT)
logger.info("Starting FXRuby test")
app = FXApp.new
if ARGV[0] == "--test"
    main_window = FXMainWindow.new(app, "Hello World App", :width => 250, :height => 100)
    FXLabel.new(main_window, "Hello, World!")
    app.create
    main_window.show(PLACEMENT_SCREEN)
    app.run
end
exit 0
