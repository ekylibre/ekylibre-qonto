# frozen_string_literal: true

module Qonto
  # The same document can reach the inbox twice (uploaded and e-mailed, or sent
  # again by the supplier). Qonto's own has_duplicates flag does not catch
  # them. The older one is the original; the later ones are flagged, never
  # removed: the accountant decides.
  #
  # Same supplier (by name, or entity when unnamed), same kind, same invoice
  # number. Documents without a number are never compared.
  class InboundDuplicates
    # @param inbounds [Array<InboundInvoice>] the ones about to be displayed
    # @return [Hash{Integer => InboundInvoice}] flagged id => its original
    def self.originals_for(inbounds)
      shown = Array(inbounds).map(&:id)
      return {} if shown.empty?

      groups = InboundInvoice.where.not(invoice_number: [nil, ''])
                             .select(:id, :kind, :entity_id, :supplier_name, :invoice_number, :created_at)
                             .group_by { |i| key(i) }
      groups.values.each_with_object({}) do |group, found|
        next if group.size < 2

        original, *twins = group.sort_by { |i| [i.created_at, i.id] }
        twins.each { |twin| found[twin.id] = original if shown.include?(twin.id) }
      end
    end

    def self.key(inbound)
      supplier = Reference.normalize(inbound.supplier_name).presence || "entity-#{inbound.entity_id}"
      [inbound.kind, supplier, Reference.normalize(inbound.invoice_number)]
    end
    private_class_method :key
  end
end
