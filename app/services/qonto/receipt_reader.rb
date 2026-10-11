# frozen_string_literal: true

require 'open3'
require 'timeout'

module Qonto
  # Reads a supplier document (PDF, picture) on this server and says what it
  # contains: total, date, number, SIRET, VAT split. Local only: the work is
  # done by lib/ekylibre-qonto/read_receipt.py (PyMuPDF, tesseract for scans)
  # and nothing leaves the machine. What it finds is a hint, never an order:
  # the caller checks it against what the bank paid.
  #
  # Absent tooling (no python3 or PyMuPDF) is not an error: #read returns nil.
  class ReceiptReader
    SCRIPT = File.expand_path('../../../lib/ekylibre-qonto/read_receipt.py', __dir__)
    TIMEOUT = 90
    TOLERANCE = BigDecimal('0.01')

    Result = Struct.new(:method, :total, :total_candidates, :date, :number, :siret, :vat_number, :vat_lines, :vat_consistent, keyword_init: true) do
      # Is one of the amounts written next to a "total" what was paid?
      def total_matches?(amount)
        amount = amount.to_d
        total_candidates.any? { |candidate| (candidate - amount).abs <= TOLERANCE }
      end

      # The VAT split is trusted only when it adds up to the amount paid.
      def vat_split_for(amount)
        return [] unless vat_consistent && vat_lines.any?

        vat_lines.sum { |l| l[:total] } == amount.to_d ? vat_lines : []
      end

      def date_on
        Date.iso8601(date) if date
      rescue ArgumentError
        nil
      end
    end

    # @param document [Document, nil]
    # @return [Result, nil]
    def self.read(document)
      return nil unless document&.file&.path && File.exist?(document.file.path)

      Rails.cache.fetch(['qonto', 'receipt', document.id, document.updated_at.to_i], expires_in: 30.days) do
        new(document.file.path).read
      end
    end

    def initialize(path)
      @path = path
    end

    def read
      output, status = run
      return nil unless status&.success?

      build(JSON.parse(output))
    rescue JSON::ParserError, Timeout::Error, Errno::ENOENT => e
      Rails.logger.warn("[Qonto][receipt] #{e.class}: #{e.message}")
      nil
    end

    private

      # Neutral working directory: Python puts the current directory on its
      # module path.
      def run
        Timeout.timeout(TIMEOUT) do
          out, _err, status = Open3.capture3('python3', SCRIPT, @path, chdir: Dir.tmpdir)
          [out, status]
        end
      end

      def build(data)
        Result.new(
          method: data['method'], total: decimal(data['total']), total_candidates: Array(data['total_candidates']).map { |v| decimal(v) },
          date: data['date'], number: data['number'], siret: data['siret'], vat_number: data['vat_number'],
          vat_lines: Array(data['vat_lines']).map { |l| l.to_h.transform_keys(&:to_sym).transform_values { |v| decimal(v) } },
          vat_consistent: data['vat_consistent'] == true
        )
      end

      def decimal(value)
        value.nil? ? nil : BigDecimal(value.to_s)
      end
  end
end
