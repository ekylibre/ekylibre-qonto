# frozen_string_literal: true

module Qonto
  # Who a bank line was paid to, when Qonto holds no document that says so.
  # The best evidence is what the accountant already did: a line of the same
  # label (or the same counterparty IBAN) that was reconciled with a payment
  # to a supplier. Then the bank details and the name of the entities.
  #
  # An ambiguous answer is no answer: the label "AMAZON" paid to two suppliers
  # stays unresolved rather than guessed.
  #
  #   how :learned_label  the same label was paid to this supplier before
  #       :learned_iban   the same counterparty account was
  #       :iban           an entity carries this bank account
  #       :name           the counterparty name is the name of one entity
  class SupplierResolver
    Result = Struct.new(:entity, :how, :evidence, keyword_init: true)

    # Share of the past payments that must agree.
    AGREEMENT = 0.75

    HISTORY_SQL = <<~SQL
      SELECT bsi.name AS label, bsi.provider->'data'->>'counterparty_iban' AS iban, op.payee_id AS payee_id
      FROM bank_statement_items bsi
      JOIN journal_entry_items jei ON jei.bank_statement_id = bsi.bank_statement_id AND jei.bank_statement_letter = bsi.letter
      JOIN journal_entries je ON je.id = jei.entry_id AND je.resource_type = 'OutgoingPayment'
      JOIN outgoing_payments op ON op.id = je.resource_id
      WHERE bsi.provider->>'vendor' = 'qonto' AND bsi.debit > 0 AND bsi.letter <> ''
    SQL

    def self.normalize_label(text)
      text.to_s.downcase.gsub(/[^[:alnum:]]+/, ' ').strip
    end

    def self.normalize_iban(text)
      text.to_s.gsub(/\s/, '').upcase
    end

    def initialize
      @by_label = Hash.new { |h, k| h[k] = Hash.new(0) }
      @by_iban = Hash.new { |h, k| h[k] = Hash.new(0) }
      load_history
      @entities = {}
    end

    # @param item [BankStatementItem]
    # @return [Result, nil]
    def resolve(item)
      data = provider_data(item)
      label = self.class.normalize_label(item.name)
      iban = self.class.normalize_iban(data['counterparty_iban'])

      from_history(@by_label[label], :learned_label) ||
        (iban.present? && from_history(@by_iban[iban], :learned_iban)) ||
        (iban.present? && from_iban(iban)) ||
        from_name(self.class.normalize_label(data['counterparty_name'])) ||
        from_name(label)
    end

    private

      def load_history
        ActiveRecord::Base.connection.select_all(HISTORY_SQL).each do |row|
          next if row['payee_id'].blank?

          @by_label[self.class.normalize_label(row['label'])][row['payee_id'].to_i] += 1
          iban = self.class.normalize_iban(row['iban'])
          @by_iban[iban][row['payee_id'].to_i] += 1 if iban.present?
        end
      end

      def provider_data(item)
        provider = (item.provider || {}).to_h
        (provider[:data] || provider['data']).to_h.stringify_keys
      end

      def from_history(counts, how)
        return nil if counts.empty?

        total = counts.values.sum
        payee_id, top = counts.max_by { |_, count| count }
        return nil if top.to_f / total < AGREEMENT

        entity = Entity.find_by(id: payee_id)
        entity && Result.new(entity: entity, how: how, evidence: total)
      end

      def from_iban(iban)
        matches = entity_ibans[iban]
        matches&.one? ? Result.new(entity: Entity.find_by(id: matches.first), how: :iban, evidence: 1) : nil
      end

      def from_name(name)
        return nil if name.blank?

        matches = entity_names[name]
        matches&.one? ? Result.new(entity: Entity.find_by(id: matches.first), how: :name, evidence: 1) : nil
      end

      def entity_ibans
        @entity_ibans ||= Entity.where.not(iban: [nil, '']).pluck(:id, :iban).group_by { |_, iban| self.class.normalize_iban(iban) }.transform_values { |rows| rows.map(&:first) }
      end

      def entity_names
        @entity_names ||= Entity.pluck(:id, :full_name).group_by { |_, name| self.class.normalize_label(name) }.transform_values { |rows| rows.map(&:first) }
      end
  end
end
