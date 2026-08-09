# -*- encoding: utf-8 -*-
# stub: color 1.8 ruby lib

Gem::Specification.new do |s|
  s.name = "color".freeze
  s.version = "1.8".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Austin Ziegler".freeze, "Matt Lyon".freeze]
  s.date = "2015-10-26"
  s.description = "Color is a Ruby library to provide basic RGB, CMYK, HSL, and other colourspace\nmanipulation support to applications that require it. It also provides 152\nnamed RGB colours (184 with spelling variations) that are commonly supported in\nHTML, SVG, and X11 applications. A technique for generating monochromatic\ncontrasting palettes is also included.\n\nThe Color library performs purely mathematical manipulation of the colours\nbased on colour theory without reference to colour profiles (such as sRGB or\nAdobe RGB). For most purposes, when working with RGB and HSL colour spaces,\nthis won't matter. Absolute colour spaces (like CIE L*a*b* and XYZ) and cannot\nbe reliably converted to relative colour spaces (like RGB) without colour\nprofiles.\n\nColor 1.8 adds an alpha parameter to all <tt>#css_rgba</tt> calls, fixes a bug\nexposed by new constant lookup semantics in Ruby 2, and ensures that\n<tt>Color.equivalent?</tt> can only be called on Color instances.\n\nBarring bugs introduced in this release, this (really) is the last version of\ncolor that supports Ruby 1.8, so make sure that your gem specification is set\nproperly (to <tt>~> 1.8</tt>) if that matters for your application. This\nversion will no longer be supported one year after the release of color 2.0.".freeze
  s.email = ["halostatue@gmail.com".freeze, "matt@postsomnia.com".freeze]
  s.extra_rdoc_files = ["Code-of-Conduct.rdoc".freeze, "Contributing.rdoc".freeze, "History.rdoc".freeze, "Licence.rdoc".freeze, "Manifest.txt".freeze, "README.rdoc".freeze]
  s.files = ["Code-of-Conduct.rdoc".freeze, "Contributing.rdoc".freeze, "History.rdoc".freeze, "Licence.rdoc".freeze, "Manifest.txt".freeze, "README.rdoc".freeze]
  s.homepage = "https://github.com/halostatue/color".freeze
  s.licenses = ["MIT".freeze]
  s.rdoc_options = ["--main".freeze, "README.rdoc".freeze]
  s.rubygems_version = "2.4.8".freeze
  s.summary = "Color is a Ruby library to provide basic RGB, CMYK, HSL, and other colourspace manipulation support to applications that require it".freeze

  s.installed_by_version = "3.6.7".freeze

  s.specification_version = 4

  s.add_development_dependency(%q<minitest>.freeze, ["~> 5.8".freeze])
  s.add_development_dependency(%q<rdoc>.freeze, ["~> 4.0".freeze])
  s.add_development_dependency(%q<hoe-doofus>.freeze, ["~> 1.0".freeze])
  s.add_development_dependency(%q<hoe-gemspec2>.freeze, ["~> 1.1".freeze])
  s.add_development_dependency(%q<hoe-git>.freeze, ["~> 1.6".freeze])
  s.add_development_dependency(%q<hoe-travis>.freeze, ["~> 1.2".freeze])
  s.add_development_dependency(%q<minitest-around>.freeze, ["~> 0.3".freeze])
  s.add_development_dependency(%q<minitest-autotest>.freeze, ["~> 1.0".freeze])
  s.add_development_dependency(%q<minitest-bisect>.freeze, ["~> 1.2".freeze])
  s.add_development_dependency(%q<minitest-focus>.freeze, ["~> 1.1".freeze])
  s.add_development_dependency(%q<minitest-moar>.freeze, ["~> 0.0".freeze])
  s.add_development_dependency(%q<minitest-pretty_diff>.freeze, ["~> 0.1".freeze])
  s.add_development_dependency(%q<rake>.freeze, ["~> 10.0".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, ["~> 0.7".freeze])
  s.add_development_dependency(%q<hoe>.freeze, ["~> 3.14".freeze])
end
