class Dynamic
  def method_missing(name, *args)
    name.to_s
  end

  %w[a b].each { |n| define_method(n) { n } }
end
