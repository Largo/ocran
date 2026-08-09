# -*- encoding: utf-8 -*-
# stub: hoe 4.6.1 ruby lib

Gem::Specification.new do |s|
  s.name = "hoe".freeze
  s.version = "4.6.1".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 3.0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "bug_tracker_uri" => "https://github.com/seattlerb/hoe/issues", "changelog_uri" => "https://github.com/seattlerb/hoe/blob/master/History.rdoc", "documentation_uri" => "https://docs.seattlerb.org/hoe/", "homepage_uri" => "https://zenspider.com/projects/hoe.html", "source_code_uri" => "https://github.com/seattlerb/hoe" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Ryan Davis".freeze]
  s.cert_chain = ["-----BEGIN CERTIFICATE-----\nMIIDPjCCAiagAwIBAgIBCjANBgkqhkiG9w0BAQsFADBFMRMwEQYDVQQDDApyeWFu\nZC1ydWJ5MRkwFwYKCZImiZPyLGQBGRYJemVuc3BpZGVyMRMwEQYKCZImiZPyLGQB\nGRYDY29tMB4XDTI2MDEwNzAxMDkxNFoXDTI3MDEwNzAxMDkxNFowRTETMBEGA1UE\nAwwKcnlhbmQtcnVieTEZMBcGCgmSJomT8ixkARkWCXplbnNwaWRlcjETMBEGCgmS\nJomT8ixkARkWA2NvbTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALda\nb9DCgK+627gPJkB6XfjZ1itoOQvpqH1EXScSaba9/S2VF22VYQbXU1xQXL/WzCkx\ntaCPaLmfYIaFcHHCSY4hYDJijRQkLxPeB3xbOfzfLoBDbjvx5JxgJxUjmGa7xhcT\noOvjtt5P8+GSK9zLzxQP0gVLS/D0FmoE44XuDr3iQkVS2ujU5zZL84mMNqNB1znh\nGiadM9GHRaDiaxuX0cIUBj19T01mVE2iymf9I6bEsiayK/n6QujtyCbTWsAS9Rqt\nqhtV7HJxNKuPj/JFH0D2cswvzznE/a5FOYO68g+YCuFi5L8wZuuM8zzdwjrWHqSV\ngBEfoTEGr7Zii72cx+sCAwEAAaM5MDcwCQYDVR0TBAIwADALBgNVHQ8EBAMCBLAw\nHQYDVR0OBBYEFEfFe9md/r/tj/Wmwpy+MI8d9k/hMA0GCSqGSIb3DQEBCwUAA4IB\nAQA/X8/PKTTc/IkYQEUL6XWtfK8fAfbuLJzmLcz6f2ZWrtBvPsYvqRuwI1bWUtil\n2ibJEfIuSIHX6BsUTX18+hlaIussf6EWq/YkE7e2BKmgQE42vSOZMce0kCEAPbx0\nrQtqonfWTHQ8UbQ7GqCL3gDQ0QDD2B+HUlb4uaCZ2icxqa/eOtxMvHC2tj+h0xKY\nxL84ipM5kr0bHGf9/MRZJWcw51urueNycBXu1Xh+pEN8qBmYsFRR4SIODLClybAO\n6cbm2PyPQgKNiqE4H+IQrDVHd9bJs1XgLElk3qoaJBWXc/5fy0J1imYb25UqmiHG\nsnGe1hrppvBRdcyEzvhfIPjI\n-----END CERTIFICATE-----\n".freeze]
  s.date = "1980-01-02"
  s.description = "Hoe is a rake/rubygems helper for project Rakefiles. It helps you\nmanage, maintain, and release your project and includes a dynamic\nplug-in system allowing for easy extensibility. Hoe ships with\nplug-ins for all your usual project tasks including rdoc generation,\ntesting, packaging, deployment, and announcement.\n\nSee class rdoc for help. Hint: `ri Hoe` or any of the plugins listed\nbelow.\n\nFor extra goodness, see: https://docs.seattlerb.org/hoe/Hoe.pdf\n\n== Features/Problems:\n\n* Includes a dynamic plug-in system allowing for easy extensibility.\n* Auto-intuits changes, description, summary, and version.\n* Uses a manifest for safe and secure deployment.\n* Provides 'sow' for quick project directory creation.\n* Sow uses a simple ERB templating system allowing you to capture your\n  project patterns.".freeze
  s.email = ["ryand-ruby@zenspider.com".freeze]
  s.executables = ["sow".freeze]
  s.extra_rdoc_files = ["History.rdoc".freeze, "Manifest.txt".freeze, "README.rdoc".freeze]
  s.files = ["History.rdoc".freeze, "Manifest.txt".freeze, "README.rdoc".freeze, "bin/sow".freeze]
  s.homepage = "https://zenspider.com/projects/hoe.html".freeze
  s.licenses = ["MIT".freeze]
  s.rdoc_options = ["--main".freeze, "README.rdoc".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 3.2".freeze)
  s.rubygems_version = "3.7.2".freeze
  s.summary = "Hoe is a rake/rubygems helper for project Rakefiles".freeze

  s.installed_by_version = "3.6.7".freeze

  s.specification_version = 4

  s.add_runtime_dependency(%q<rake>.freeze, ["~> 13.0".freeze])
  s.add_development_dependency(%q<rdoc>.freeze, [">= 6.0".freeze, "< 8".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, ["~> 0.21".freeze])
end
