$LOAD_PATH.push File.expand_path('lib', __dir__)

# Maintain your gem's version:
require 'ekylibre-qonto/version'

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = 'ekylibre-qonto'
  s.version     = EkylibreQonto::VERSION
  s.authors     = ['DJ']
  s.email       = ['djoulin@ekylibre.com']
  s.summary     = 'Qonto plugin for Ekylibre'
  s.description = 'Qonto plugin for Ekylibre'
  s.license     = 'MIT'

  s.files = Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.rdoc', 'Capfile']
  s.require_path = ['lib']
  s.test_files = Dir['test/**/*']
end
