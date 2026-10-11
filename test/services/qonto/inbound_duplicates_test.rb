# frozen_string_literal: true

require 'test_helper'
require_relative '../../test_helper'

# The same document reaching the inbox twice (uploaded and e-mailed): the later
# one is flagged, never removed.
class Qonto::InboundDuplicatesTest < ::Ekylibre::Testing::ApplicationTestCase::WithFixtures
  def test_the_later_copy_is_flagged_with_its_original
    original = doc('FA-1', created_at: 3.days.ago)
    copy = doc('FA-1', created_at: 1.day.ago)

    found = Qonto::InboundDuplicates.originals_for([original, copy])

    assert_equal [copy.id], found.keys
    assert_equal original.id, found[copy.id].id
  end

  def test_the_number_is_compared_whatever_its_punctuation
    original = doc('FA 2026/1', created_at: 3.days.ago)
    copy = doc('fa-2026-1', created_at: 1.day.ago)

    assert_equal [copy.id], Qonto::InboundDuplicates.originals_for([copy]).keys
    assert_equal original.id, Qonto::InboundDuplicates.originals_for([copy])[copy.id].id
  end

  def test_the_original_is_never_flagged
    original = doc('FA-1', created_at: 3.days.ago)
    doc('FA-1', created_at: 1.day.ago)

    assert_empty Qonto::InboundDuplicates.originals_for([original])
  end

  def test_only_what_is_displayed_is_reported_but_the_whole_inbox_is_searched
    original = doc('FA-1', status: 'ignored', created_at: 3.days.ago) # on another tab
    copy = doc('FA-1', created_at: 1.day.ago)

    assert_equal original.id, Qonto::InboundDuplicates.originals_for([copy])[copy.id].id
  end

  def test_three_copies_all_point_to_the_oldest
    oldest = doc('FA-1', created_at: 5.days.ago)
    second = doc('FA-1', created_at: 3.days.ago)
    third = doc('FA-1', created_at: 1.day.ago)

    found = Qonto::InboundDuplicates.originals_for([oldest, second, third])

    assert_equal [second.id, third.id].sort, found.keys.sort
    assert_equal [oldest.id], found.values.map(&:id).uniq
  end

  def test_another_supplier_another_kind_or_another_number_is_not_a_duplicate
    base = doc('FA-1', created_at: 3.days.ago)
    others = [doc('FA-1', supplier: 'Another SAS'), doc('FA-1', kind: 'receipt'), doc('FA-2')]

    assert_empty Qonto::InboundDuplicates.originals_for([base] + others)
  end

  def test_documents_without_number_are_never_compared
    first = doc(nil, created_at: 3.days.ago)
    second = doc('', created_at: 1.day.ago)

    assert_empty Qonto::InboundDuplicates.originals_for([first, second])
  end

  def test_an_unnamed_supplier_falls_back_on_the_linked_entity
    a = doc('FA-1', supplier: nil, entity: entities(:entities_008), created_at: 3.days.ago)
    b = doc('FA-1', supplier: nil, entity: entities(:entities_008), created_at: 1.day.ago)
    c = doc('FA-1', supplier: nil, entity: entities(:entities_009), created_at: 1.day.ago)

    assert_equal [b.id], Qonto::InboundDuplicates.originals_for([a, b, c]).keys
  end

  def test_nothing_to_show_nothing_to_search
    assert_equal({}, Qonto::InboundDuplicates.originals_for([]))
  end

  private

    def doc(number, supplier: 'Ferme Exemple', kind: 'invoice', entity: nil, status: 'to_review', created_at: Time.current)
      Qonto::InboundInvoice.create!(remote_id: SecureRandom.hex(6), invoice_number: number, supplier_name: supplier,
                                    kind: kind, entity: entity, status: status, created_at: created_at)
    end
end
