# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'
require 'tmpdir'

# The local reading of a till receipt or an invoice: PyMuPDF on a PDF built
# here, so nothing real is needed. Skipped where Python has no PyMuPDF.
class Qonto::ReceiptReaderTest < ActiveSupport::TestCase
  TICKET = <<~TEXT
    SAS BOULANGERIE EXEMPLE
    RUE DU MOULIN 17000 LA ROCHELLE
    SIRET : 123 456 782 00019
    PAIN DE CAMPAGNE        2,40 EUR A
    CAFE MOULU              5,83 EUR A
    PILES AA                9,00 EUR B
    MONTANT DU             17,23 EUR
    RECAPITULATIF TVA
    A  5,50%   7,80     0,43      8,23
    B  20,00%  7,50     1,50      9,00
    14/09/2026
  TEXT

  setup do
    skip 'python3 with PyMuPDF is not available' unless system('python3', '-c', 'import fitz', out: File::NULL, err: File::NULL)
  end

  def test_reads_the_total_the_date_the_siret_and_the_vat_split_of_a_ticket
    result = read(TICKET)

    assert_equal BigDecimal('17.23'), result.total
    assert result.total_matches?(17.23)
    assert_equal Date.new(2026, 9, 14), result.date_on
    assert_equal '12345678200019', result.siret
    assert_equal [BigDecimal('5.5'), BigDecimal('20')], result.vat_lines.map { |l| l[:rate] }
    assert result.vat_consistent
  end

  def test_the_vat_split_is_only_trusted_when_it_adds_up_to_what_was_paid
    result = read(TICKET)

    assert_equal 2, result.vat_split_for(BigDecimal('17.23')).size
    assert_empty result.vat_split_for(BigDecimal('20'))
  end

  def test_an_amount_with_a_non_breaking_space_as_thousand_separator_is_read
    result = read("Facture FA-2026-12\nTotal HT 2\u00a0500,00 EUR\nTotal TTC 3\u00a0000,00 EUR\n")

    assert result.total_matches?(3000)
    assert result.total_matches?(2500), 'both totals are candidates: the caller keeps the one that was paid'
    assert_equal 'FA-2026-12', result.number
  end

  def test_a_file_that_is_not_a_document_gives_nothing
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'x.pdf')
      File.write(path, 'not a pdf')

      result = Qonto::ReceiptReader.new(path).read

      assert(result.nil? || result.total.nil?)
    end
  end

  private

    def read(text)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'doc.pdf')
        script = "import fitz,sys\nd=fitz.open(); p=d.new_page(); p.insert_textbox(fitz.Rect(30,30,560,800), sys.argv[2], fontsize=9); d.save(sys.argv[1])"
        assert system('python3', '-c', script, path, text), 'could not build the PDF'
        Qonto::ReceiptReader.new(path).read
      end
    end
end
