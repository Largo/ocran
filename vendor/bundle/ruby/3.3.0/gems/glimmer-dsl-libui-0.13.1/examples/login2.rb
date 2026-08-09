require 'glimmer-dsl-libui'

class Login
  include Glimmer
  
  attr_accessor :username, :password, :logged_in
  
  def logged_out
    !logged_in
  end
  
  def launch
    window('Login') {
      margined true
      
      vertical_box {
        form {
          entry {
            label 'Username:'
            text <=> [self, :username]
            enabled <= [self, :logged_out, computed_by: :logged_in] # computed_by option ensures being notified of changes to logged_in
          }
          
          password_entry {
            label 'Password:'
            text <=> [self, :password]
            enabled <= [self, :logged_out, computed_by: :logged_in]
          }
        }
        
        horizontal_box {
          button('Login') {
            enabled <= [self, :logged_out, computed_by: :logged_in]
            
            on_clicked do
              self.logged_in = true
            end
          }
          
          button('Logout') {
            enabled <= [self, :logged_in]
            
            on_clicked do
              self.logged_in = false
              self.username = ''
              self.password = ''
            end
          }
        }
      }
    }.show
  end
end

Login.new.launch
