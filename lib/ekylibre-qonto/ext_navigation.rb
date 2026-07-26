# frozen_string_literal: true

module EkylibreQonto
  # Merges the plugin's navigation.xml items into the existing Ekylibre
  # navigation tree (same approach as ekylibre-banking).
  class ExtNavigation
    def self.add_navigation_xml_to_existing_tree
      new.build_new_tree
    end

    attr_reader :qonto_navigation_tree, :new_navigation_tree

    def initialize
      @qonto_navigation_tree = Ekylibre::Navigation::Tree
                                 .load_file(navigation_file_path, :navigation, %i[part group item])
    end

    def build_new_tree
      @qonto_navigation_tree.children.each do |part|
        navigation_part = Ekylibre::Navigation.tree.get(part.name)
        next unless navigation_part

        part.children.each do |group|
          navigation_group = navigation_part.get(group.name)
          next unless navigation_group

          group.children.each do |item|
            navigation_item = navigation_group.get(item.name)
            unless navigation_item
              navigation_group.add_child(item)
              navigation_item = navigation_group.children.last
            end
            item.pages.each { |page| navigation_item.add_page(page) }
          end
        end
      end
      @new_navigation_tree = Ekylibre::Navigation.tree
      @new_navigation_tree.rebuild_index!
      @new_navigation_tree
    end

    private

      def navigation_file_path
        EkylibreQonto.root.join('config', 'navigation.xml')
      end
  end
end
