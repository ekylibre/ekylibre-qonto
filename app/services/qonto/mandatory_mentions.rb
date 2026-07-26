# frozen_string_literal: true

module Qonto
  # Pre-flight check of the e-invoicing mandatory mentions (Lot 4). Sending an
  # invoice that misses them earns a per-invoice penalty and a PA rejection, so
  # emission is guarded on completeness — never invoicing itself (the law
  # requires transmitting, not blocking billing).
  #
  # Two mentions are now derived from the accounting data instead of being
  # entered by hand:
  #   * the operation category (goods / services / mixed) is read off the sale
  #     lines' variety;
  #   * the VAT payment option (debits vs payments) is the tax declaration mode
  #     of the current financial year.
  class MandatoryMentions
    OPERATION_CATEGORIES = %w[goods services mixed].freeze

    def initialize(sale)
      @sale = sale
    end

    # @return [Array<Symbol>] the missing mandatory mentions
    def missing
      missing = []
      missing << :client_siren       unless @sale.client&.siren_number.present?
      missing << :delivery_address   unless @sale.delivery_address_id.present?
      missing << :operation_category if operation_category.blank?
      missing << :vat_payment_option unless vat_option_declared?
      missing
    end

    def complete?
      missing.empty?
    end

    # Derived from the sale lines: "goods", "services" or "mixed". nil when no
    # line lets us determine it (e.g. an empty draft) — then it counts as
    # missing.
    def operation_category
      natures = @sale.items.map { |item| line_operation_category(item) }.compact.uniq
      return nil if natures.empty?

      natures.length > 1 ? 'mixed' : natures.first
    end

    private

      # A line is a service when its variant's variety maps to the :service
      # nature (electricity, immatter, property_title, service); everything else
      # is billed as goods.
      def line_operation_category(item)
        variant = item.variant
        return nil unless variant

        variant.nature&.find_nature == :service ? 'services' : 'goods'
      end

      # The VAT payment option is the tax declaration mode of the current
      # financial year. `none` means the regime has not been set up yet, so the
      # option is not declared.
      def vat_option_declared?
        fy = FinancialYear.current
        fy.present? && !fy.tax_declaration_mode_none?
      end
  end
end
