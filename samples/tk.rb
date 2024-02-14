# How to use ocran with TK:
# ocran tk.rb --windows --gem-full=tk --add-all-core --no-autoload
# You will need to add other gems manually or using the "--gemfile Gemfile" command

require 'tk'
root = TkRoot.new { title "Hello, World!" }
TkLabel.new(root) do
   text 'Hello, World!'
   pack { padx 15 ; pady 15; side 'left' }
end
Tk.mainloop unless defined?(Ocran)
