# frozen_string_literal: true

module Qonto
  # What a purchase made from a Qonto document starts with when nobody chose:
  # the nature, the placeholder variant and the tax of a VAT rate. Read-only
  # lookups, shared by the creation from the inbox and by the suggestions made
  # from the bank lines.
  module PurchaseDefaults
    DEFAULT_VARIANT_PREFERENCE = :qonto_default_purchase_variant_id

    module_function

    def default_nature
      PurchaseNature.by_default || PurchaseNature.first
    end

    # The expense report nature is found by its name, in either supported
    # language, so a tenant that switched locale does not get a second one.
    def expense_nature
      names = %i[eng fra].map { |locale| I18n.t('labels.expense_report_nature', locale: locale, default: '') }.reject(&:blank?)
      PurchaseNature.where(name: names).first
    end

    # Custom preference: read the row directly (Preference[] only accepts
    # predefined preferences).
    def default_variant
      id = Preference.find_by(name: DEFAULT_VARIANT_PREFERENCE.to_s)&.value
      id.present? ? ProductNatureVariant.find_by(id: id) : nil
    end

    def tax_for(rate)
      amount = to_decimal(rate)
      return nil if amount.nil?

      Tax.where(amount: amount).reorder(:id).first
    end

    def to_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
