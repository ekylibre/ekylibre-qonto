require 'ekylibre-qonto/engine'

module EkylibreQonto
  def self.root
    Pathname.new(File.dirname(__dir__))
  end
end
