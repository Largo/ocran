require "sqlite3"

unless defined?(Ocran)
  db = SQLite3::Database.new(":memory:")
  db.execute("create table t (a integer)")
  db.execute("insert into t values (7)")
  puts "sqlite:#{db.execute("select a from t").first.first}"
  puts "sqlite3_gem:#{SQLite3::VERSION}"
  puts "platform:#{RUBY_PLATFORM}"
end
