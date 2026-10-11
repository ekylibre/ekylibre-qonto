# frozen_string_literal: true

module Qonto
  # Invoice numbers are typed by people and printed by software: "FA 2026/001",
  # "fa-2026-001" and "FA2026001" are the same invoice. Comparisons go through
  # this form, in Ruby and, for the database side, the matching SQL.
  module Reference
    # Same as .normalize, as an SQL expression on a column or expression.
    def self.sql(expression)
      "UPPER(REGEXP_REPLACE(#{expression}, '[^A-Za-z0-9]', '', 'g'))"
    end

    def self.normalize(value)
      value.to_s.upcase.gsub(/[^A-Z0-9]/, '')
    end
  end
end
